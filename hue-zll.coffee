# Hue ZLL Pimatic plugin

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  t = env.require('decl-api').types

  # node-hue-api needs es6-promise
  es6Promise = require 'es6-promise'
  hueapi = require 'node-hue-api'

  Queue = require 'simple-promise-queue'
  es6PromiseRetry = require 'promise-retry'

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueQueue extends Queue
    constructor: (options) ->
      super(options)
      @maxLength = options.maxLength or Infinity
      @bindObject = options.bindObject

    pushTask: (promiseFunction) ->
      if @length < @maxLength
        # Convert ES6 Promise to Bluebird
        return Promise.resolve super(promiseFunction)
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
      retries = retryOptions.retries or @defaultRetries
      errorFunction = retryOptions.errorFunction or (
        (error, number, retries, retryFunction) =>
          error.message = "Error during Hue API request (attempt #{number}): " + error.message
          if retries - number + 1 > 0
            env.logger.debug error.message
            env.logger.debug "Retrying (#{retries - number + 1} more) Hue API request"
          retryFunction(error)
      )

      return promiseRetry(
        ( (retryFunction, number) =>
          @pushRequest(
            request, args...
          ).catch( (error) =>
            errorFunction error, number, retries, retryFunction
          )
        ),
        retries: retries
      )

  # Convert ES6 Promise to Bluebird
  promiseRetry = (args...) => Promise.resolve es6PromiseRetry args...

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @hueApi = new hueapi.HueApi(
        @config.host,
        @config.username,
        @config.timeout,
        @config.port
      )

      BaseHueDevice.hueQ.concurrency = @config.hueApiConcurrency
      BaseHueDevice.hueQ.timeout = @config.timeout
      BaseHueDevice.hueQ.defaultRetries = @config.retries
      BaseHueDevice.hueQ.bindObject = @hueApi

      BaseHueDevice.bridgeVersion(@hueApi)
      BaseHueLight.inventory(@hueApi)
      BaseHueLightGroup.inventory(@hueApi)

      deviceConfigDef = require("./device-config-schema")

      deviceClasses = [
        HueZLLOnOffLight,
        HueZLLOnOffLightGroup,
        HueZLLDimmableLight,
        HueZLLDimmableLightGroup,
        HueZLLColorTempLight,
        HueZLLColorTempLightGroup,
        HueZLLColorLight,
        HueZLLColorLightGroup,
        HueZLLExtendedColorLight,
        HueZLLExtendedColorLightGroup,
        HueZLLScenes
      ]
      for DeviceClass in deviceClasses
        do (DeviceClass) =>
          @framework.deviceManager.registerDeviceClass(DeviceClass.name, {
            configDef: deviceConfigDef[DeviceClass.name],
            prepareConfig: @prepareConfig,
            createCallback: (deviceConfig) => new DeviceClass(deviceConfig, @hueApi, @config)
          })

      actions = require("./actions") env
      @framework.ruleManager.addActionProvider(new actions.HueZLLDimmerActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.CtActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.HueSatActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.ActivateHueSceneActionProvider(@framework))

      @framework.on "after init", =>
        # Check if the mobile-frontent was loaded and get a instance
        mobileFrontend = @framework.pluginManager.getPlugin 'mobile-frontend'
        if mobileFrontend?
          mobileFrontend.registerAssetFile 'js',
            "pimatic-hue-zll/node_modules/spectrum-colorpicker/spectrum.js"
          mobileFrontend.registerAssetFile 'css',
            "pimatic-hue-zll/node_modules/spectrum-colorpicker/spectrum.css"
          mobileFrontend.registerAssetFile 'js', "pimatic-hue-zll/app/hue-zll-light.coffee"
          mobileFrontend.registerAssetFile 'css', "pimatic-hue-zll/app/hue-zll-light.css"
          mobileFrontend.registerAssetFile 'html', "pimatic-hue-zll/app/hue-zll-light.jade"
        else
          env.logger.warn "mobile-frontend not loaded, no gui will be available"

        if @config.hueApiQueueMaxLength > 0
          # Override the default auto calculated maximum queue length
          BaseHueLight.hueQ.maxLength = @config.hueApiQueueMaxLength

    prepareConfig: (deviceConfig) ->
      deviceConfig.name = "" unless deviceConfig.name?

  class BaseHueDevice
    @hueQ: new HueQueue({
      maxLength: 4  # Incremented for each additional device
      autoStart: true
    })

    @bridgeVersion: (hueApi) ->
      BaseHueDevice.hueQ.retryRequest(
        hueApi.version,
        [],
        retries: 2
      ).then( (version) =>
        env.logger.info "Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}"
      ).catch( (error) =>
        env.logger.error "Error while attempting to retrieve the Hue bridge version:", error.message
      )

    @_apiPollingError: (error, number, retries, retryFunction, pollDescr) =>
      error.message = "Error while polling #{pollDescr} (attempt #{number}): " + error.message
      switch error.code
        when 'ECONNRESET'
          error.message += " (connection reset)"
      if retries > 0
        env.logger.debug error.message
        env.logger.debug "Retrying (#{retries} more) Hue API poll #{pollDescr} request"
        retryFunction(error)  # Throws an error
      else
        return Promise.reject error

    constructor: (@device, @pluginConfig, @hueApi) ->
      BaseHueDevice.hueQ.maxLength++

  class BaseHueLight extends BaseHueDevice
    devDescr: "light"

    @globalPolling: null
    @statusCallbacks: {}

    # Static methods for polling all lights

    @inventory: (hueApi) ->
      BaseHueDevice.hueQ.retryRequest(
        hueApi.lights
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
      return promiseRetry(
        ( (retryFunction, number) =>
          BaseHueDevice.hueQ.pushRequest(
            @hueApi.lights
          ).catch( (error) =>
            BaseHueDevice._apiPollingError(
              error,
              number,
              retries - number + 1,
              retryFunction,
              "all lights"
            )
          )
        ),
        retries: retries
      ).then(
        BaseHueLight.allLightsReceived
      ).catch( (error) =>
        env.logger.error error.message
      )

    poll: (retries=@pluginConfig.retries) =>
      return promiseRetry(
        ( (retryFunction, number) =>
          BaseHueDevice.hueQ.pushRequest(
            @hueApi.lightStatus, @hueId
          ).catch( (error) =>
            BaseHueDevice._apiPollingError(
              error,
              number,
              retries - number + 1,
              retryFunction,
              "light #{@hueId}"
            )
          )
        ),
        retries: retries
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

    prepareStateChange: ->
      @pendingStateChange = hueapi.lightState.create()
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
        hueApi.groups
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
      return promiseRetry(
        ( (retryFunction, number) =>
          BaseHueDevice.hueQ.pushRequest(
            @hueApi.groups
          ).catch( (error) =>
            BaseHueDevice._apiPollingError(
              error,
              number,
              retries - number + 1,
              retryFunction,
              "all light groups"
            )
          )
        ),
        retries: retries
      ).then(
        BaseHueLightGroup.allGroupsReceived
      ).catch( (error) =>
        env.logger.error error.message
      )

    poll: (retries=@pluginConfig.retries) =>
      return promiseRetry(
        ( (retryFunction, number) =>
          BaseHueDevice.hueQ.pushRequest(
            @hueApi.getGroup, @hueId
          ).catch( (error) =>
            BaseHueDevice._apiPollingError(
              error,
              number,
              retries - number + 1,
              retryFunction,
              "group #{@hueId}"
            )
          )
        ),
        retries: retries
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
      return @scenesPromise = BaseHueDevice.hueQ.pushRequest(
        @hueApi.scenes
      ).then(
        @_scenesReceived
      ).catch(
        @_apiError
      )

    _scenesReceived: (result) =>
      nameRegex = /^(.+) (on|off) (\d+)$/
      for scene in result
        try
          tokens = scene.name.match(nameRegex)
          if tokens?
            scene.uniquename = tokens[1]
            lcname = scene.uniquename.toLowerCase()
            @scenesByName[lcname] = scene
          else
            scene.uniquename = scene.name
            @scenesByName[scene.name.toLowerCase()] = scene
        catch error
          env.logger.error error.message

    _lookupSceneByName: (sceneName) => Promise.join @scenesPromise, ( => @scenesByName[sceneName.toLowerCase()] )

    activateSceneByName: (sceneName, groupId=null) ->
      return @_lookupSceneByName(sceneName).then( (scene) =>
        if scene? and scene.id?
          return BaseHueLightGroup.hueQ.pushTask( (resolve, reject) =>
            env.logger.debug "Activating Hue scene id: #{scene.id} name: \"#{sceneName}\"" + \
              if groupId? then " group: #{groupId}" else ""
            @hueApi.activateScene(scene.id, groupId).then(resolve, reject)
          )
        else
          return Promise.reject(Error("Scene with name #{sceneName} not found"))
      )

  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: BaseHueLight

    _reachable: null

    template: "huezllonoff"

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = if @config.name.length isnt 0 then @config.name else "#{@constructor.name}_#{@id}"
      @extendAttributesActions()
      super()

      @hue = new @HueClass(this, @_pluginConfig, @hueApi, @config.hueId)
      @hue.deviceStateCallback = @_lightStateReceived

      if @config.polling < 0
        # Enable global polling (for all lights or groups)
        @lightStateInitialized = @hue.setupGlobalPolling(@_pluginConfig.polling, @_pluginConfig.retries * 8)
      else
        @lightStateInitialized = @hue.setupPolling(@config.polling, @_pluginConfig.retries * 8)
      @lightStateInitialized.then(@_replaceName) if @config.name.length is 0

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        reachable:
          description: "Light is reachable?"
          type: t.boolean

    # Wait on first poll on initialization
    waitForInit: (callback) => Promise.join @lightStateInitialized, callback

    getState: -> @waitForInit ( => @_state )
    getReachable: -> @waitForInit ( => @_reachable )

    poll: -> @hue.poll()

    saveLightState: (transitionTime=null) => @waitForInit ( =>
      hueStateChange = hueapi.lightState.create @filterConflictingState @hue.getLightStatus().state
      hueStateChange.transition(transitionTime) if transitionTime?
      return hueStateChange
    )

    restoreLightState: (stateChange) =>
      return @hue.changeHueState(stateChange).then( => @_lightStateReceived(stateChange.payload()) )

    _lightStateReceived: (rstate) =>
      @_setState rstate.on
      @_setReachable rstate.reachable
      return rstate

    _replaceName: =>
      if @hue.name? and @hue.name.length isnt 0
        env.logger.info("Changing name of #{@constructor.name} device #{@id} " +
          "from \"#{@name}\" to \"#{@hue.name}\"")
        @updateName @hue.name

    changeStateTo: (state) ->
      hueStateChange = @hue.prepareStateChange().on(state)
      return @hue.changeHueState(hueStateChange).then( ( => @_setState state) )

    _setReachable: (reachable) ->
      unless @_reachable is reachable
        @_reachable = reachable
        @emit "reachable", reachable

  class HueZLLOnOffLightGroup extends HueZLLOnOffLight
    HueClass: BaseHueLightGroup

  class HueZLLDimmableLight extends HueZLLOnOffLight
    HueClass: BaseHueLight

    _dimlevel: null

    template: "huezlldimmable"

    extendAttributesActions: () =>
      super()

      @attributes = extend (extend {}, @attributes),
        dimlevel:
          description: "The current dim level"
          type: t.number
          unit: "%"

      @actions = extend (extend {}, @actions),
        changeDimlevelTo:
          description: "Sets the level of the dimmer"
          params:
            dimlevel:
              type: t.number

    # Wait on first poll on initialization
    getDimlevel: -> @waitForInit ( => @_dimlevel )

    _lightStateReceived: (rstate) =>
      super(rstate)
      @_setDimlevel rstate.bri / 254 * 100
      return rstate

    changeDimlevelTo: (state, transitionTime=null) ->
      hueStateChange = @hue.prepareStateChange().on(true).bri(state / 100 * 254)
      hueStateChange.transition(transitionTime) if transitionTime?
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setDimlevel state
      ) )

    _setDimlevel: (level) =>
      level = parseFloat(level)
      assert(not isNaN(level))
      assert 0 <= level <= 100
      unless @_dimlevel is level
        @_dimlevel = level
        @emit "dimlevel", level

  class HueZLLDimmableLightGroup extends HueZLLDimmableLight
    HueClass: BaseHueLightGroup

  ColorTempMixin =
    _ct: null    

    changeCtTo: (ct, transitionTime=null) ->
      hueStateChange = @hue.prepareStateChange().on(true).ct(ct)
      hueStateChange.transition(transitionTime) if transitionTime?
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setCt ct
      ) )

    _setCt: (ct) ->
      ct = parseFloat(ct)
      assert not isNaN(ct)
      assert 153 <= ct <= 500
      unless @_ct is ct
        @_ct = ct
        @emit "ct", ct

    getCt: -> @waitForInit ( => @_ct )

  ColormodeMixin =
    _colormode: null

    _setColormode: (colormode) ->
      unless @_colormode is colormode
        @_colormode = colormode
        @emit "colormode", colormode

    getColormode: -> @waitForInit ( => @_colormode )

  class HueZLLColorTempLight extends HueZLLDimmableLight
    HueClass: BaseHueLight

    template: "huezllcolortemp"

    extendAttributesActions: () =>
      super()

      @attributes = extend (extend {}, @attributes),
        ct:
          description: "the color temperature"
          type: t.number
        colormode:
          description: "the mode of color last set"
          type: t.string

      @actions = extend (extend {}, @actions),
        changeCtTo:
          description: "changes the color temperature"
          params:
            ct:
              type: t.number

    _lightStateReceived: (rstate) =>
      super(rstate)
      @_setCt rstate.ct
      @_setColormode rstate.colormode if rstate.colormode?
      return rstate

    filterConflictingState: (state) ->
      filteredState = {}
      filteredState[k] = v for k, v of state when not state.colormode? or not (
        (k in ['hue','sat'] and state.colormode != 'hs') or
          (k == 'xy' and state.colormode != 'xy') or (k == 'ct' and state.colormode != 'ct'))
      return filteredState

  extend HueZLLColorTempLight.prototype, ColorTempMixin
  extend HueZLLColorTempLight.prototype, ColormodeMixin

  class HueZLLColorTempLightGroup extends HueZLLColorTempLight
    HueClass: BaseHueLightGroup

  extend HueZLLColorTempLightGroup.prototype, ColorTempMixin
  extend HueZLLColorTempLightGroup.prototype, ColormodeMixin

  class HueZLLColorLight extends HueZLLDimmableLight
    HueClass: BaseHueLight

    _hue: null
    _sat: null

    template: "huezllcolor"

    extendAttributesActions: () =>
      super()

      @attributes = extend (extend {}, @attributes),
        hue:
          description: "the color hue value"
          type: t.number
          unit: "%"
        sat:
          description: "the color saturation value"
          type: t.number
          unit: "%"
        colormode:
          description: "the mode of color last set"
          type: t.string

      @actions = extend (extend {}, @actions),
        changeHueTo:
          description: "changes the color hue"
          params:
            hue:
              type: t.number
        changeSatTo:
          description: "changes the color saturation"
          params:
            sat:
              type: t.number
        changeHueSatTo:
          description: "changes the color hue and saturation"
          params:
            hue:
              type: t.number
            sat:
              type: t.number

    _lightStateReceived: (rstate) =>
      super(rstate)
      @_setHue (rstate.hue / 65535 * 100) if rstate.hue?
      @_setSat (rstate.sat / 254 * 100) if rstate.sat?
      @_setColormode rstate.colormode if rstate.colormode?
      return rstate

    changeHueTo: (hue, transitionTime=null) ->
      hueStateChange = @hue.prepareStateChange().on(true).hue(hue / 100 * 65535)
      hueStateChange.transition(transitionTime) if transitionTime?
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setHue hue
      ) )

    changeSatTo: (sat, transitionTime=null) ->
      hueStateChange = @hue.prepareStateChange().on(true).sat(sat / 100 * 254)
      hueStateChange.transition(transitionTime) if transitionTime?
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setSat sat
      ) )

    changeHueSatTo: (hue, sat, transitionTime=null) ->
      hueStateChange = @hue.prepareStateChange().on(true).hue(hue / 100 * 65535).sat(sat / 100 * 254)
      hueStateChange.transition(transitionTime) if transitionTime?
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setHue hue
        @_setSat sat
      ) )

    _setHue: (hueVal) ->
      hueVal = parseFloat(hueVal)
      assert not isNaN(hueVal)
      assert 0 <= hueVal <= 100
      unless @_hue is hueVal
        @_hue = hueVal
        @emit "hue", hueVal

    _setSat: (satVal) ->
      satVal = parseFloat(satVal)
      assert not isNaN(satVal)
      assert 0 <= satVal <= 100
      unless @_sat is satVal
        @_sat = satVal
        @emit "sat", satVal

    getHue: -> @waitForInit ( => @_hue )
    getSat: -> @waitForInit ( => @_sat )

    filterConflictingState: (state) ->
      filteredState = {}
      filteredState[k] = v for k, v of state when not state.colormode? or not (
        (k in ['hue','sat'] and state.colormode != 'hs') or
          (k == 'xy' and state.colormode != 'xy') or (k == 'ct' and state.colormode != 'ct'))
      return filteredState

  extend HueZLLColorLight.prototype, ColormodeMixin

  class HueZLLColorLightGroup extends HueZLLColorLight
    HueClass: BaseHueLightGroup

  extend HueZLLColorLightGroup.prototype, ColormodeMixin

  class HueZLLExtendedColorLight extends HueZLLColorLight
    HueClass: BaseHueLight

    template: "huezllextendedcolor"

    extendAttributesActions: () =>
      super()

      @attributes = extend (extend {}, @attributes),
        ct:
          description: "the color temperature"
          type: t.number

      @actions = extend (extend {}, @actions),
        changeCtTo:
          description: "changes the color temperature"
          params:
            ct:
              type: t.number

    _lightStateReceived: (rstate) =>
      super(rstate)
      @_setCt rstate.ct if rstate.ct?
      return rstate

  extend HueZLLExtendedColorLight.prototype, ColorTempMixin
  extend HueZLLExtendedColorLight.prototype, ColormodeMixin

  class HueZLLExtendedColorLightGroup extends HueZLLExtendedColorLight
    HueClass: BaseHueLightGroup
  
  extend HueZLLExtendedColorLightGroup.prototype, ColorTempMixin
  extend HueZLLExtendedColorLightGroup.prototype, ColormodeMixin

  class HueZLLScenes extends env.devices.Device
    _lastActivatedScene: null

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      @extendAttributesActions()
      super()

      @hue = new BaseHueScenes(this, @_pluginConfig, @hueApi)
      @hue.requestScenes().then( =>
        env.logger.info "Retrieved #{Object.keys(@hue.scenesByName).length} unique scenes from the Hue API:",
          ('"'+name+'"' for name in @getKnownSceneNames()).join(', ')
      )

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        lastActivatedScene:
          description: "Hue scene last activated by Pimatic"
          type: t.string

      @actions = extend (extend {}, @actions),
        activateScene:
          description: "activates a Hue scene"
          params:
            sceneName:
              type: t.string
            groupId:
              type: t.number

    activateScene: (sceneName, groupId=null) =>
      return @hue.activateSceneByName(sceneName, groupId).then( =>
        @_setLastActivatedScene sceneName
      )

    _setLastActivatedScene: (sceneName) ->
      assert sceneName.length > 0
      unless @_lastActivatedScene is sceneName
        @_lastActivatedScene = sceneName
        @emit "lastActivatedScene", sceneName

    getLastActivatedScene: -> Promise.resolve @_lastActivatedScene

    getKnownSceneNames: => (scene.uniquename for key, scene of @hue.scenesByName)


  return new HueZLLPlugin()