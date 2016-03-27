# Hue ZLL Pimatic plugin

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  t = env.require('decl-api').types

  huebase = require('./hue') env

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @hueApi = huebase.initHueApi(@config)
      huebase.BaseHueDevice.initHueQueue(@config, @hueApi)

      huebase.BaseHueDevice.bridgeVersion(@hueApi)
      huebase.BaseHueLight.inventory(@hueApi)
      huebase.BaseHueLightGroup.inventory(@hueApi)

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
          huebase.BaseHueLight.hueQ.maxLength = @config.hueApiQueueMaxLength

    prepareConfig: (deviceConfig) ->
      deviceConfig.name = "" unless deviceConfig.name?


  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: huebase.BaseHueLight

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
    HueClass: huebase.BaseHueLightGroup

  class HueZLLDimmableLight extends HueZLLOnOffLight
    HueClass: huebase.BaseHueLight

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
    HueClass: huebase.BaseHueLightGroup

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
    HueClass: huebase.BaseHueLight

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
    HueClass: huebase.BaseHueLightGroup

  extend HueZLLColorTempLightGroup.prototype, ColorTempMixin
  extend HueZLLColorTempLightGroup.prototype, ColormodeMixin

  class HueZLLColorLight extends HueZLLDimmableLight
    HueClass: huebase.BaseHueLight

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
    HueClass: huebase.BaseHueLightGroup

  extend HueZLLColorLightGroup.prototype, ColormodeMixin

  class HueZLLExtendedColorLight extends HueZLLColorLight
    HueClass: huebase.BaseHueLight

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
    HueClass: huebase.BaseHueLightGroup
  
  extend HueZLLExtendedColorLightGroup.prototype, ColorTempMixin
  extend HueZLLExtendedColorLightGroup.prototype, ColormodeMixin

  class HueZLLScenes extends env.devices.Device
    _lastActivatedScene: null

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      @extendAttributesActions()
      super()

      @hue = new huebase.BaseHueScenes(this, @_pluginConfig, @hueApi)
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