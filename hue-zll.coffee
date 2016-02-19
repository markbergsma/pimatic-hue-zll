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

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @hueApi = new hueapi.HueApi(
        @config.host,
        @config.username,
        @config.timeout,
        @config.port
      )

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
            createCallback: (deviceConfig) => new DeviceClass(deviceConfig, @hueApi, @config)
          })

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

    _hueApiRequestFailed: (error) ->
      env.logger.error("Hue API request failed!", error.message)
      return error

  class BaseHueLight

    constructor: (@device, @hueApi, @hueId) ->
      @lightState = hueapi.lightState.create()
      @lightStateResult = {}

    poll: -> @hueApi.lightStatus(@hueId).then(@_stateReceived, @_apiError)

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
      return result.state

    _mergeLightState: (stateChange) ->
      @lightState._values[k] = v for k, v of stateChange._values
      @lightState

    createLightState: -> hueapi.lightState.create()
    getLightState: -> @lightState

    setLightState: (hueState) ->
      env.logger.debug("Setting light #{@hueId} state: " + JSON.stringify(hueState._values))
      @hueApi.setLightState(@hueId, hueState).then(( => @_mergeLightState hueState), @_apiError)

    _apiError: (error) ->
      env.logger.error("Hue API request failed:", error.message)
      return error

  class BaseHueLightGroup extends BaseHueLight

    poll: -> @hueApi.getGroup(@hueId).then(@_stateReceived, @_apiError)

    _stateReceived: (result) =>
      newGroupState = hueapi.lightState.create(result.lastAction)
      diff = @_diffState(newGroupState)
      if Object.keys(diff).length > 0
        env.logger.debug("group #{@hueId} state change: " + JSON.stringify(diff))
      @lightState = newGroupState
      @lightStateResult = result
      return result.lastAction

    setLightState: (hueState) ->
      env.logger.debug("Setting group #{@hueId} state: " + JSON.stringify(hueState._values))
      @hueApi.setGroupLightState(@hueId, hueState).then(
        ( => @_mergeLightState hueState), @_apiError)

  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: BaseHueLight

    _reachable: null

    template: "huezllonoff"

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      @extendAttributesActions()
      super()

      @hue = new @HueClass(this, hueApi, @config.hueId)
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        reachable:
          description: "Light is reachable?"
          type: t.boolean

    # Wait on first poll on initialization
    getState: -> @lightStateInitialized.then(super)
    getReachable: -> Promise.join @lightStateInitialized, ( => @_reachable )

    poll: -> @hue.poll().then(@_lightStateReceived)

    _lightStateReceived: (rstate) =>
      @_setState rstate.on
      @_setReachable rstate.reachable

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

  class HueZLLColorTempLight extends HueZLLDimmableLight
    HueClass: BaseHueLight

    template: "huezllcolortemp"

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

  extend HueZLLColorTempLight.prototype, ColorTempMixin

  class HueZLLColorTempLightGroup extends HueZLLColorTempLight
    HueClass: BaseHueLightGroup

  extend HueZLLColorTempLightGroup.prototype, ColorTempMixin

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
        sat:
          description: "the color saturation value"
          type: t.number

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
      @_setHue rstate.hue
      @_setSat rstate.sat

    changeHueTo: (hue) ->
      hueState = @hue.createLightState().on(true).hue(hue)
      return @hue.setLightState(hueState).then( ( =>
        @_setState true
        @_setHue hue
      ) )

    changeSatTo: (sat) ->
      hueState = @hue.createLightState().on(true).sat(sat)
      return @hue.setLightState(hueState).then( ( =>
        @_setState true
        @_setSat sat
      ) )

    changeHueSatTo: (hue, sat) ->
      hueState = @hue.createLightState().on(true).hue(hue).sat(sat)
      return @hue.setLightState(hueState).then( ( =>
        @_setState true
        @_setHue hue
        @_setSat sat
      ) )

    _setHue: (hueVal) ->
      hueVal = parseFloat(hueVal)
      assert not isNaN(hueVal)
      assert 0 <= hueVal <= 65535
      unless @_hue is hueVal
        @_hue = hueVal
        @emit "hue", hueVal

    _setSat: (satVal) ->
      satVal = parseFloat(satVal)
      assert not isNaN(satVal)
      assert 0 <= satVal <= 254
      unless @_sat is satVal
        @_sat = satVal
        @emit "sat", satVal

    getHue: -> Promise.join @lightStateInitialized, ( => @_hue )
    getSat: -> Promise.join @lightStateInitialized, ( => @_sat )

  class HueZLLColorLightGroup extends HueZLLColorLight
    HueClass: BaseHueLightGroup

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

  extend HueZLLExtendedColorLight.prototype, ColorTempMixin

  class HueZLLExtendedColorLightGroup extends HueZLLExtendedColorLight
    HueClass: BaseHueLightGroup
  
  extend HueZLLExtendedColorLightGroup.prototype, ColorTempMixin

  return new HueZLLPlugin()