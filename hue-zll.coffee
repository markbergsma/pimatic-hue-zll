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

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueQueue extends Queue
    constructor: (options) ->
      super(options)
      @maxLength = options.maxLength or Infinity

    pushTask: (promiseFunction) ->
      if @length < @maxLength
        return super(promiseFunction)
      else
        return Promise.reject Error("Hue API maximum queue length (#{@maxLength}) exceeded")

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
        HueZLLExtendedColorLightGroup
      ]
      for DeviceClass in deviceClasses
        do (DeviceClass) =>
          @framework.deviceManager.registerDeviceClass(DeviceClass.name, {
            configDef: deviceConfigDef[DeviceClass.name],
            prepareConfig: @prepareConfig,
            createCallback: (deviceConfig) => new DeviceClass(deviceConfig, @hueApi, @config)
          })

      actions = require("./actions") env
      @framework.ruleManager.addActionProvider(new actions.CtActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.HueSatActionProvider(@framework))

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
      BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return hueApi.version().then(resolve, reject)
      ).then(( (version) =>
        env.logger.info("Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}")
        ), @_apiError)

    constructor: (@device, @hueApi) ->
      BaseHueDevice.hueQ.maxLength++

    _apiError: (error) ->
      env.logger.error("Hue API request failed:", error.message)
      throw error

  class BaseHueLight extends BaseHueDevice

    @globalPolling: null
    @statusCallbacks: {}

    # Static methods for polling all lights

    @inventory: (hueApi) ->
      BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return hueApi.lights().then(resolve, reject)
      ).then(( (result) => env.logger.debug result ), @_apiError)

    @pollAllLights: (hueApi) ->
      BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return hueApi.lights().then(resolve, reject)
      ).then(BaseHueLight.allLightsReceived)

    @allLightsReceived: (lightsResult) ->
      for light in lightsResult.lights
        if Array.isArray(BaseHueLight.statusCallbacks[light.id])
          cb(light) for cb in BaseHueLight.statusCallbacks[light.id]

    @setupGlobalPolling: (interval, hueApi) ->
      unless BaseHueLight.globalPolling?
        BaseHueLight.globalPolling = setInterval(BaseHueLight.pollAllLights, interval, hueApi)


    constructor: (@device, @hueApi, @hueId) ->
      super(@device, @hueApi)
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

    setupPolling: (interval) =>
      setInterval(( => @poll()), interval)

    poll: ->
      return BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return @hueApi.lightStatus(@hueId).then(resolve, reject)
      ).then(@_statusReceived, @_apiError)

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
        env.logger.debug "Received light #{@hueId} state change:", JSON.stringify(diff)
      @lightStatusResult = result
      @name = result.name if result.name?
      @type = result.type if result.type?

      @deviceStateCallback?(result.state)
      return result.state

    _mergeStateChange: (stateChange) ->
      @lightStatusResult.state[k] = v for k, v of stateChange.payload()
      @lightStatusResult.state

    prepareStateChange: ->
      ls = hueapi.lightState.create()
      ls.transition(@device.config.transitionTime) if @device.config.transitionTime?
      return ls

    getLightState: -> @lightStatusResult.state

    changeHueState: (hueStateChange) ->
      return BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        env.logger.debug "Changing light #{@hueId} state:", JSON.stringify(hueStateChange.payload())
        return @hueApi.setLightState(@hueId, hueStateChange).then(resolve, reject)
      ).then(( => @_mergeStateChange hueStateChange), @_apiError)

  class BaseHueLightGroup extends BaseHueLight

    @globalPolling: null
    @statusCallbacks: {}

    # Static methods for polling all lights

    @inventory: (hueApi) ->
      BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return hueApi.groups().then(resolve, reject)
      ).then(( (result) => env.logger.debug result ), @_apiError)

    @pollAllGroups: (hueApi) ->
      BaseHueDevice.hueQ.pushTask( (resolve, reject) =>
        return hueApi.groups().then(resolve, reject)
      ).then(BaseHueLightGroup.allGroupsReceived)

    @allGroupsReceived: (groupsResult) ->
      for group in groupsResult
        if Array.isArray(BaseHueLightGroup.statusCallbacks[group.id])
          cb(group) for cb in BaseHueLightGroup.statusCallbacks[group.id]

    @setupGlobalPolling: (interval, hueApi) ->
      unless BaseHueLightGroup.globalPolling?
        BaseHueLightGroup.globalPolling = setInterval(BaseHueLightGroup.pollAllGroups, interval, hueApi)


    poll: ->
      return BaseHueLightGroup.hueQ.pushTask( (resolve, reject) =>
        @hueApi.getGroup(@hueId).then(resolve, reject)
      ).then(@_statusReceived, @_apiError)

    _statusReceived: (result) =>
      stateObj = result.lastAction or result.action
      diff = @_diffState(stateObj)
      if Object.keys(diff).length > 0
        env.logger.debug "Received group #{@hueId} state change:", JSON.stringify(diff)
      result.state = stateObj
      delete result.lastAction if result.lastAction?
      delete result.action if result.action?
      @lightStatusResult = result
      @name = result.name if result.name?
      @type = result.type if result.type?

      @deviceStateCallback?(stateObj)
      return stateObj

    changeHueState: (hueStateChange) ->
      return BaseHueLightGroup.hueQ.pushTask( (resolve, reject) =>
        env.logger.debug "Changing group #{@hueId} state:", JSON.stringify(hueStateChange.payload())
        @hueApi.setGroupLightState(@hueId, hueStateChange).then(resolve, reject)
      ).then(( => @_mergeStateChange hueStateChange), @_apiError)

  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: BaseHueLight

    _reachable: null

    template: "huezllonoff"

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = if @config.name.length isnt 0 then @config.name else "#{@constructor.name}_#{@id}"
      @extendAttributesActions()
      super()

      @hue = new @HueClass(this, hueApi, @config.hueId)
      @hue.deviceStateCallback = @_lightStateReceived
      # Enable global polling (for all lights or groups)
      @HueClass.setupGlobalPolling(@_pluginConfig.polling, hueApi)

      @hue.setupPolling(@config.polling or @_pluginConfig.polling) unless @config.polling < 0
      @lightStateInitialized = @poll()
      @lightStateInitialized.then(@_replaceName) if @config.name.length is 0

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        reachable:
          description: "Light is reachable?"
          type: t.boolean

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, ( => @_state )
    getReachable: -> Promise.join @lightStateInitialized, ( => @_reachable )

    poll: -> @hue.poll()

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
    getDimlevel: -> Promise.join @lightStateInitialized, ( => @_dimlevel )

    _lightStateReceived: (rstate) =>
      super(rstate)
      @_setDimlevel rstate.bri / 254 * 100
      return rstate

    changeDimlevelTo: (state) ->
      hueStateChange = @hue.prepareStateChange().on(true).bri(state / 100 * 254)
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

    changeCtTo: (ct) ->
      hueStateChange = @hue.prepareStateChange().on(true).ct(ct)
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

    getCt: -> Promise.join @lightStateInitialized, ( => @_ct )

  ColormodeMixin =
    _colormode: null

    _setColormode: (colormode) ->
      unless @_colormode is colormode
        @_colormode = colormode
        @emit "colormode", colormode

    getColormode: -> Promise.join @lightStateInitialized, ( => @_colormode )

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
      @_setHue (rstate.hue / 65535 * 100)
      @_setSat (rstate.sat / 254 * 100)
      @_setColormode rstate.colormode if rstate.colormode?
      return rstate

    changeHueTo: (hue) ->
      hueStateChange = @hue.prepareStateChange().on(true).hue(hue / 100 * 65535)
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setHue hue
      ) )

    changeSatTo: (sat) ->
      hueStateChange = @hue.prepareStateChange().on(true).sat(sat / 100 * 254)
      return @hue.changeHueState(hueStateChange).then( ( =>
        @_setState true
        @_setSat sat
      ) )

    changeHueSatTo: (hue, sat) ->
      hueStateChange = @hue.prepareStateChange().on(true).hue(hue / 100 * 65535).sat(sat / 100 * 254)
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

    getHue: -> Promise.join @lightStateInitialized, ( => @_hue )
    getSat: -> Promise.join @lightStateInitialized, ( => @_sat )

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
      @_setCt rstate.ct
      return rstate

  extend HueZLLExtendedColorLight.prototype, ColorTempMixin
  extend HueZLLExtendedColorLight.prototype, ColormodeMixin

  class HueZLLExtendedColorLightGroup extends HueZLLExtendedColorLight
    HueClass: BaseHueLightGroup
  
  extend HueZLLExtendedColorLightGroup.prototype, ColorTempMixin
  extend HueZLLExtendedColorLightGroup.prototype, ColormodeMixin

  return new HueZLLPlugin()