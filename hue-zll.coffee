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

      BaseHueLight.hueQ.concurrency = @config.hueApiConcurrency
      BaseHueLight.hueQ.timeout = @config.timeout

      @hueApi.version().then(( (version) =>
        env.logger.info("Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}")
      ), @_hueApiRequestFailed)
      @hueApi.lights().then(( (result) => env.logger.debug result), @_hueApiRequestFailed)
      @hueApi.groups().then(( (result) => env.logger.debug result), @_hueApiRequestFailed)

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

    _hueApiRequestFailed: (error) ->
      env.logger.error("Hue API request failed!", error.message)
      return error

    prepareConfig: (deviceConfig) ->
      deviceConfig.name = "" unless deviceConfig.name?

  class BaseHueLight
    @hueQ: new HueQueue({
      maxLength: 4  # Incremented for each additional device
      autoStart: true
    })

    constructor: (@device, @hueApi, @hueId) ->
      @lightState = hueapi.lightState.create()
      @lightStateResult = {}
      BaseHueLight.hueQ.maxLength++

    poll: ->
      return BaseHueLight.hueQ.pushTask( (resolve, reject) =>
        return @hueApi.lightStatus(@hueId).then(resolve)
      ).then(@_stateReceived, @_apiError)

    _diffState: (newLightState) ->
      diff = {}
      diff[k] = v for k, v of newLightState._values when (
          not @lightState._values[k]? or
          k == 'xy' and ((v[0] != @lightState._values['xy'][0]) or
            (v[1] != @lightState._values['xy'][1])) or
          (k != 'xy' and @lightState._values[k] != v))
      return diff

    _stateReceived: (result) =>
      newLightState = hueapi.lightState.create(result.state)
      diff = @_diffState(newLightState)
      if Object.keys(diff).length > 0
        env.logger.debug("light #{@hueId} state change: " + JSON.stringify(diff))
      @lightState = newLightState
      @lightStateResult = result
      @name = result.name if result.name?
      @type = result.type if result.type?
      return result.state

    _mergeLightState: (stateChange) ->
      @lightState._values[k] = v for k, v of stateChange._values
      @lightState

    createLightState: ->
      ls = hueapi.lightState.create()
      ls.transition(@device.config.transitionTime) if @device.config.transitionTime?
      return ls

    getLightState: -> @lightState

    setLightState: (hueState) ->
      return BaseHueLight.hueQ.pushTask( (resolve, reject) =>
        env.logger.debug("Setting light #{@hueId} state: " + JSON.stringify(hueState._values))
        return @hueApi.setLightState(@hueId, hueState).then(resolve)
      ).then(( => @_mergeLightState hueState), @_apiError)

    _apiError: (error) ->
      env.logger.error("Hue API request failed:", error.message)
      throw error

  class BaseHueLightGroup extends BaseHueLight

    poll: ->
      return BaseHueLightGroup.hueQ.pushTask( (resolve, reject) =>
        @hueApi.getGroup(@hueId).then(resolve)
      ).then(@_stateReceived, @_apiError)

    _stateReceived: (result) =>
      newGroupState = hueapi.lightState.create(result.lastAction)
      diff = @_diffState(newGroupState)
      if Object.keys(diff).length > 0
        env.logger.debug("group #{@hueId} state change: " + JSON.stringify(diff))
      @lightState = newGroupState
      @lightStateResult = result
      @name = result.name if result.name?
      @type = result.type if result.type?
      return result.lastAction

    setLightState: (hueState) ->
      return BaseHueLightGroup.hueQ.pushTask( (resolve, reject) =>
        env.logger.debug("Setting group #{@hueId} state: " + JSON.stringify(hueState._values))
        @hueApi.setGroupLightState(@hueId, hueState).then(resolve)
      ).then(( => @_mergeLightState hueState), @_apiError)

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
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @config.polling or @_pluginConfig.polling)
      @lightStateInitialized.then(@_replaceName) if @config.name.length is 0

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        reachable:
          description: "Light is reachable?"
          type: t.boolean

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, ( => @_state )
    getReachable: -> Promise.join @lightStateInitialized, ( => @_reachable )

    poll: -> @hue.poll().then(@_lightStateReceived, ( -> ))

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
      hueState = @hue.createLightState().on(state)
      return @hue.setLightState(hueState).then( ( => @_setState state) )

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
      hueState = @hue.createLightState().on(true).bri(state / 100 * 254)
      return @hue.setLightState(hueState).then( ( =>
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
      hueState = @hue.createLightState().on(true).ct(ct)
      return @hue.setLightState(hueState).then( ( =>
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
      hueState = @hue.createLightState().on(true).hue(hue / 100 * 65535)
      return @hue.setLightState(hueState).then( ( =>
        @_setState true
        @_setHue hue
      ) )

    changeSatTo: (sat) ->
      hueState = @hue.createLightState().on(true).sat(sat / 100 * 254)
      return @hue.setLightState(hueState).then( ( =>
        @_setState true
        @_setSat sat
      ) )

    changeHueSatTo: (hue, sat) ->
      hueState = @hue.createLightState().on(true).hue(hue / 100 * 65535).sat(sat / 100 * 254)
      return @hue.setLightState(hueState).then( ( =>
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