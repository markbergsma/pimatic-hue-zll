# Hue API specific classes and functions

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  # node-hue-api needs es6-promise
  es6Promise = require 'es6-promise'
  hueapi = require 'node-hue-api'

  Queue = require 'simple-promise-queue'
  es6PromiseRetry = require 'promise-retry'

  Queue.setPromise(Promise)

  class HueQueue extends Queue

    @defaultErrorFunction: (error, number, retries, retryFunction, descr) =>
      error.message = "Error during #{descr} Hue API request (attempt #{number}/#{retries+1}): " + error.message
      if not error.code? then throw error # Only retry for system errors
      switch error.code
        when 'ECONNRESET'
          error.message += " (connection reset)"
      if number < retries + 1
        env.logger.debug error.message
      retryFunction(error)  # Throws an error

    constructor: (options) ->
      super(options)
      @maxLength = options.maxLength or Infinity
      @bindObject = options.bindObject

    pushTask: (promiseFunction) ->
      if @length < @maxLength
        return super(promiseFunction)
      else
        return Promise.reject Error("Hue API maximum queue length (#{@maxLength}) exceeded")

    pushRequest: (request, args...) ->
      return @pushTask(
        (resolve, reject) =>
          request.bind(@bindObject)(args..., (err, result) =>
            if err
              reject err
            else
              resolve result
          )
      )

    retryRequest: (request, args=[], retryOptions={}) ->
      assert request instanceof Function
      assert Array.isArray(args)
      retries = retryOptions.retries or @defaultRetries
      errorFunction = retryOptions.errorFunction or HueQueue.defaultErrorFunction
      descr = retryOptions.descr or "a"
      assert errorFunction instanceof Function

      return promiseRetry(
        ( (retryFunction, number) =>
          @pushRequest(
            request, args...
          ).catch( (error) =>
            errorFunction error, number, retries, retryFunction, descr
          )
        ),
        retries: retries
      )

  # Convert ES6 Promise to Bluebird
  promiseRetry = (args...) => Promise.resolve es6PromiseRetry args...

  initHueApi = (config) ->
    return new hueapi.HueApi(
      config.host,
      config.username,
      config.timeout,
      config.port
    )

  class BaseHueDevice
    @hueQ: new HueQueue({
      maxLength: 4  # Incremented for each additional device
      autoStart: true
    })

    @initHueQueue: (config, hueApi) ->
      BaseHueDevice.hueQ.concurrency = config.hueApiConcurrency
      BaseHueDevice.hueQ.timeout = config.timeout
      BaseHueDevice.hueQ.defaultRetries = config.retries
      BaseHueDevice.hueQ.bindObject = hueApi

    @bridgeVersion: (hueApi) ->
      BaseHueDevice.hueQ.retryRequest(
        hueApi.version,
        [],
        retries: 2,
        descr: "bridge version"
      ).then( (version) =>
        env.logger.info "Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}"
      ).catch( (error) =>
        env.logger.error "Error while attempting to retrieve the Hue bridge version:", error.message
      )

    constructor: (@device, @pluginConfig, @hueApi) ->
      BaseHueDevice.hueQ.maxLength++

  class BaseHueLight extends BaseHueDevice
    devDescr: "light"

    @globalPolling: null
    @statusCallbacks: {}

    # Static methods for polling all lights

    @inventory: (hueApi) ->
      BaseHueDevice.hueQ.retryRequest(
        hueApi.lights, [],
        descr: "lights inventory"
      ).then( (result) =>
        env.logger.debug result
      ).catch( (error) =>
        env.logger.error "Error while retrieving inventory of all lights:", error.message
      )

    @allLightsReceived: (lightsResult) ->
      for light in lightsResult.lights
        if Array.isArray(BaseHueLight.statusCallbacks[light.id])
          cb(light) for cb in BaseHueLight.statusCallbacks[light.id]

    constructor: (@device, @pluginConfig, @hueApi, @hueId) ->
      super(@device, @pluginConfig, @hueApi)
      @pendingStateChange = null
      @lightStatusResult =
        state: {}
      @deviceStateCallback = null
      @_setupStatusPolling()

    _setupStatusPolling: ->
      @registerStatusHandler(@_statusReceived)

    registerStatusHandler: (callback, hueId=@hueId) ->
      if Array.isArray(@constructor.statusCallbacks[hueId])
        @constructor.statusCallbacks[hueId].push(callback)
      else
        @constructor.statusCallbacks[hueId] = Array(callback)

    setupGlobalPolling: (interval, retries) ->
      repeatPoll = () =>
        firstPoll = @pollAllLights(retries)
        firstPoll.delay(interval).finally( =>
          repeatPoll()
          return null
        )
        return firstPoll
      return BaseHueLight.globalPolling or
        BaseHueLight.globalPolling = repeatPoll()

    setupPolling: (interval, retries) =>
      repeatPoll = () =>
        firstPoll = @poll(retries)
        firstPoll.delay(interval).finally( =>
            repeatPoll()
            return null
          )
        return firstPoll
      return if interval > 0 then repeatPoll() else @poll(retries)

    pollAllLights: (retries=@pluginConfig.retries) =>
      return BaseHueDevice.hueQ.retryRequest(@hueApi.lights, [],
        retries: retries,
        descr: "poll of all lights"
      ).then(
        BaseHueLight.allLightsReceived
      ).catch( (error) =>
        env.logger.error error.message
      )

    poll: (retries=@pluginConfig.retries) =>
      return BaseHueDevice.hueQ.retryRequest(@hueApi.lightStatus, [@hueId],
        retries: retries,
        descr: "poll of light #{@hueId}"
      ).then(
        @_statusReceived
      ).catch( (error) =>
        env.logger.error "Error while polling light #{@hueId} status:", error.message
      )

    _diffState: (newRState) ->
      assert @lightStatusResult?.state?
      lstate = @lightStatusResult.state
      diff = {}
      diff[k] = v for k, v of newRState when (
          not lstate[k]? or
          (k == 'xy' and ((v[0] != lstate['xy'][0]) or (v[1] != lstate['xy'][1]))) or
          (k != 'xy' and lstate[k] != v))
      return diff

    _statusReceived: (result) =>
      diff = @_diffState(result.state)
      if Object.keys(diff).length > 0
        env.logger.debug "Received #{@devDescr} #{@hueId} state change:", JSON.stringify(diff)
      @lightStatusResult = result
      @name = result.name if result.name?
      @type = result.type if result.type?

      @deviceStateCallback?(result.state)
      return result.state

    _mergeStateChange: (stateChange) ->
      @lightStatusResult.state[k] = v for k, v of stateChange.payload()
      @lightStatusResult.state

    createStateChange: (json) -> hueapi.lightState.create json

    prepareStateChange: ->
      @pendingStateChange = @createStateChange()
      @pendingStateChange.transition(@device.config.transitionTime) if @device.config.transitionTime?
      return @pendingStateChange

    getLightStatus: -> @lightStatusResult

    _hueStateChangeFunction: -> @hueApi.setLightState

    changeHueState: (hueStateChange) ->
      retryHueStateChange = (remainingRetries) =>
        return BaseHueDevice.hueQ.pushRequest(
          @_hueStateChangeFunction(), @hueId, hueStateChange
        ).catch(
          (error) =>
            switch error.code
              when 'ECONNRESET'
                repeat = yes
                error.message += " (connection reset)"
              else
                repeat = no
            error.message = "Error while changing #{@devDescr} state: " + error.message
            if repeat and remainingRetries > 0
              env.logger.debug error.message
              env.logger.debug """
              Retrying (#{remainingRetries} more) Hue API #{@devDescr} state change request for hue id #{@hueId}
              """
              return retryHueStateChange(remainingRetries - 1)
            else
              return Promise.reject error
        )

      return retryHueStateChange(@pluginConfig.retries).then( =>
        env.logger.debug "Changing #{@devDescr} #{@hueId} state:", JSON.stringify(hueStateChange.payload())
        @_mergeStateChange hueStateChange
      ).finally( =>
        @pendingStateChange = null  # Start with a clean state
      )

  class BaseHueLightGroup extends BaseHueLight
    devDescr: "group"

    @globalPolling: null
    @statusCallbacks: {}

    # Static methods for polling all lights

    @inventory: (hueApi) ->
      BaseHueDevice.hueQ.retryRequest(
        hueApi.groups, [],
        descr: "groups inventory"
      ).then( (result) =>
        env.logger.debug result
      ).catch( (error) =>
        env.logger.error "Error while retrieving inventory of all light groups:", error.message
      )

    @allGroupsReceived: (groupsResult) ->
      for group in groupsResult
        if Array.isArray(BaseHueLightGroup.statusCallbacks[group.id])
          cb(group) for cb in BaseHueLightGroup.statusCallbacks[group.id]

    setupGlobalPolling: (interval, retries) ->
      repeatPoll = () =>
        firstPoll = @pollAllGroups(retries)
        firstPoll.delay(interval).finally( =>
          repeatPoll()
          return null
        )
        return firstPoll
      return BaseHueLightGroup.globalPolling or
        BaseHueLightGroup.globalPolling = repeatPoll()

    pollAllGroups: (retries=@pluginConfig.retries) =>
      return BaseHueDevice.hueQ.retryRequest(@hueApi.groups, [],
        retries: retries,
        descr: "poll of all light groups"
      ).then(
        BaseHueLightGroup.allGroupsReceived
      ).catch( (error) =>
        env.logger.error error.message
      )

    poll: (retries=@pluginConfig.retries) =>
      return BaseHueDevice.hueQ.retryRequest(@hueApi.getGroup, [@hueId],
        retries: retries,
        descr: "poll of group #{@hueId}"
      ).then(
        @_statusReceived
      ).catch( (error) =>
        env.logger.error "Error while polling light group #{@hueId} status:", error.message
      )

    _statusReceived: (result) =>
      # Light groups don't have a .state object, but a .lastAction or .action instead
      result.state = result.lastAction or result.action
      delete result.lastAction if result.lastAction?
      delete result.action if result.action?
      return super(result)

    _hueStateChangeFunction: -> @hueApi.setGroupLightState


  class BaseHueScenes extends BaseHueDevice

    constructor: (@device, @pluginConfig, @hueApi) ->
      super(@device, @pluginConfig, @hueApi)
      @scenesByName = {}
      @scenesPromise = null

    requestScenes: ->
      return @scenesPromise = BaseHueDevice.hueQ.retryRequest(
        @hueApi.scenes, [],
        descr: "scenes"
      ).then(
        @_scenesReceived
      )

    _scenesReceived: (result) =>
      nameRegex = /^(.+) (on|off) (\d+)$/
      for scene in result
        try
          tokens = scene.name.match(nameRegex)
          scene.uniquename = if tokens? then tokens[1] else scene.name
          scene.lastupdatedts = Date.parse(scene.lastupdated) or 0
          lcname = scene.uniquename.toLowerCase()
          @scenesByName[lcname] = scene unless scene.lastupdatedts < @scenesByName[lcname]?.lastupdatedts
        catch error
          env.logger.error error.message

    _lookupSceneByName: (sceneName) => Promise.join @scenesPromise, ( => @scenesByName[sceneName.toLowerCase()] )

    activateSceneByName: (sceneName, groupId=null) ->
      return @_lookupSceneByName(sceneName).then( (scene) =>
        if scene? and scene.id?
          return BaseHueLightGroup.hueQ.retryRequest(
            @hueApi.activateScene, [scene.id, groupId],
            descr: "scene activation"
          ).then( =>
            env.logger.debug "Activating Hue scene id: #{scene.id} name: \"#{sceneName}\"" + \
              if groupId? then " group: #{groupId}" else ""
          )
        else
          return Promise.reject(Error("Scene with name #{sceneName} not found"))
      )


  return exports = {
    initHueApi,
    HueQueue,
    BaseHueDevice,
    BaseHueLight,
    BaseHueLightGroup,
    BaseHueScenes
  }