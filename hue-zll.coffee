# Hue ZLL Pimatic plugin

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  t = env.require('decl-api').types

  commons = require('pimatic-plugin-commons')(env)

  huebase = require('./hue') env

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      deviceConfigDef = require("./device-config-schema")

      @_base = commons.base(@, 'Plugin')

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
            prepareConfig: HueZLLOnOffLight.prepareConfig,
            createCallback: (deviceConfig) => new DeviceClass(deviceConfig, this)
          })

      actions = require("./actions") env
      @framework.ruleManager.addActionProvider(new actions.HueZLLDimmerActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.CtActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.HueSatActionProvider(@framework))
      @framework.ruleManager.addActionProvider(new actions.ActivateHueSceneActionProvider(@framework))

      if @config.username?.length > 0
        @hueApiAvailable = @discoverBridge().then =>
          env.logger.info "Requesting status of lights, light groups and scenes from the Hue API"
      else
        env.logger.warn "Hue bridge username/key is not defined in the configuration. Please run device discovery."
        @hueApiAvailable = Promise.reject Error("Hue bridge username/key unavailable")
        @hueApiAvailable.suppressUnhandledRejections()

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

      @framework.deviceManager.on "discover", @onDiscover

    prepareConfig: (pConf) ->
      # Previous versions unintentionally added a 'name' property to the plugin config in newer Pimatic versions
      delete pConf['name'] if pConf['name']?

    onDiscover: (eventData) =>
      @discoverBridge(eventData
      ).then( (host) =>
        @registerUser(host, eventData.time)
      ).then( =>
        env.logger.debug "Starting discovery of Hue devices"

        lightsInventoryPromise = huebase.BaseHueLight.discover(@hueApi)
        groupsInventoryPromise = huebase.BaseHueLightGroup.discover(@hueApi)
        lightsInventoryPromise.then(@discoverLights)
        Promise.join lightsInventoryPromise, groupsInventoryPromise, @discoverLightGroups

        # Create a BaseHueScenes instance for the purpose of this discovery
        huescenes = new huebase.BaseHueScenes(null, this)
        huescenes.requestScenes().then(@discoverScenes)
      )

    discoverBridge: (eventData) =>
      if @config.host?.length > 0
        # If the Hue bridge hostname or ip is manually configured in the configuration, use that
        apiPromise = Promise.resolve(@config.host)
      else
        # If not, start discovery of the bridge
        @framework.deviceManager.discoverMessage(
          'pimatic-hue-zll',
          "No Hue bridge defined in the configuration, starting automatic search for the Hue bridge"
        )
        apiPromise = huebase.searchBridge(Math.min(eventData?.time or 5000, 5000)
        ).then( (ipaddr) =>
          @framework.deviceManager.discoverMessage(
            'pimatic-hue-zll',
            "Found Hue bridge on ip #{ipaddr}. " + \
              "(To avoid auto-discovery on startup, add \"host\": \"#{ipaddr}\" to the plugin config.)"
          )
          return ipaddr
        ).catch( (error) =>
          @framework.deviceManager.discoverMessage(
            'pimatic-hue-zll',
            error.message
          )
          throw error
        )
      return apiPromise.then(@initApi)

    registerUser: (hostname, timeout) =>
      timeout = Math.min(timeout, 30000)
      if @config.username?.length > 0
        return Promise.resolve [hostname, @config.username]
      else
        @framework.deviceManager.discoverMessage(
          'pimatic-hue-zll',
          "No Hue API username (key) defined in the configuration. Attempting to register; " + \
            "Please press the link button on the Hue bridge within #{timeout / 1000}s!"
        )
        os = require "os"
        return huebase.registerUser(
          @hueApi, hostname, "pimatic-hue-zll##{os.hostname()}", timeout
        ).then( (apiKey) =>
          @framework.deviceManager.discoverMessage(
            'pimatic-hue-zll',
            "Created Hue API key #{apiKey}. Adding it to the plugin configuration."
          )
          @config.username = apiKey
          @initApi(hostname)
          return [hostname, apiKey]
        ).catch( (error) =>
          @framework.deviceManager.discoverMessage(
            'pimatic-hue-zll',
            "Hue API username registration failed; #{error.message}"
          )
          throw error
        )

    initApi: (hostOrIp) =>
      env.logger.debug "(Re)Initializing Hue API using host #{hostOrIp}"
      # Make a shallow copy of @config to avoid actually changing the configuration
      config = extend {}, @config
      config.host = hostOrIp
      # Initialize hueApi for the plugin
      @hueApi = huebase.initHueApi(config)
      return hostOrIp

    discoverLights: (lightsInventory) =>
      env.logger.debug "Hue API lights inventory:"
      env.logger.debug lightsInventory

      hueLights = {}
      for id, dev of @framework.deviceManager.devices
        if dev instanceof HueZLLOnOffLight and dev.constructor.name.match(/^HueZLL.+Light$/)
          hueLights[dev.config.hueId] = dev

      for light in lightsInventory.lights
        deviceClass = HueZLLPlugin.deviceClass(light.type)
        if deviceClass?
          if not hueLights[light.id]?
            config = {
              class: deviceClass,
              name: light.name,
              hueId: light.id
            }
            config['ignoreReachability'] = true if light.manufacturername.toLowerCase() is "osram"
            descr = "#{config.name} (#{light.manufacturername} #{light.modelid}) [#{light.type}]"

            @framework.deviceManager.discoveredDevice(
              'pimatic-hue-zll',
              "Hue light #{config.hueId}: #{descr}",
              config
            )
          else
            env.logger.debug "Skipping known hue light id #{light.id}"
        else
          env.logger.warn "Could not classify hue light id #{light.id}, type: #{light.type}"

    discoverLightGroups: (lightsInventory, groupsInventory) =>
      env.logger.debug "Hue API light groups inventory:"
      env.logger.debug groupsInventory

      hueLightGroups = {}
      for id, dev of @framework.deviceManager.devices
        if dev instanceof HueZLLOnOffLight and dev.constructor.name.match(/^HueZLL.+LightGroup$/)
          hueLightGroups[dev.config.hueId] = dev

      for group in groupsInventory
        group.id = parseInt(group.id)
        if not hueLightGroups[group.id]?
          if group.lights? or group.id is 0
            # Attempt to find the appropriate light group type (class) based on the capabilities of the
            # lights in the group
            if group.lights?
              groupLights = (parseInt(id) for id in group.lights)
            else if group.id is 0
              groupLights = (parseInt(light.id) for light in lightsInventory.lights)
            lightTypes = (HueZLLPlugin.deviceClass(light.type) for light in lightsInventory.lights \
              when parseInt(light.id) in groupLights)
            deviceClass = lightTypes.reduce (devClass, d) ->
              if devClass is d
                devClass
              else if devClass is 'HueZLLExtendedColorLight'
                d
              else if devClass in ['HueZLLColorTempLight','HueZLLColorLight'] and d isnt 'HueZLLExtendedColorLight'
                'HueZLLDimmableLight'
              else if devClass is 'HueZLLDimmableLight' and d is 'HueZLLOnOffLight'
                d
              else
                devClass
            deviceClass += 'Group'
          else
            deviceClass = 'HueZLLExtendedColorLightGroup' # No info available, so let's provide all functionality

          config = {
            class: deviceClass,
            name: group.name,
            hueId: group.id
          }
          descr = config.name
          if config.hueId is 0
            descr += " (all lights)"
          else if groupLights?
            descr += " (lights #{groupLights})"

          @framework.deviceManager.discoveredDevice(
            'pimatic-hue-zll',
            "Hue light group #{config.hueId}: #{descr}",
            config
          )
        else
          env.logger.debug "Skipping known hue light group id #{group.id}"

    discoverScenes: (scenes) =>
      env.logger.debug "Hue API scenes inventory:"
      env.logger.debug scenes

      # Avoid duplicates
      scenesList = (scene.nameid for key, scene of scenes)
      for devid, dev of @framework.deviceManager.devices when dev instanceof HueZLLScenes
        for button in dev.config.buttons
          scenesList = scenesList.filter( (elt) -> elt isnt button.id )

      unless scenesList.length is 0
        config = {
          class: HueZLLScenes.name,
          id: @_base.generateDeviceId(@framework, 'hue-scenes'),
          name: "Hue Scenes",
          buttons: ({id: scene.nameid, text: scene.uniquename} for k, scene of scenes when scene.nameid in scenesList)
        }
        descr = (scene.uniquename for key, scene of scenes when scene.nameid in scenesList).join(', ')
        @framework.deviceManager.discoveredDevice(
          'pimatic-hue-zll',
          "Hue scenes: #{descr}",
          config
        )

    @deviceClass: (deviceType) ->
      return switch deviceType
        when "On/Off plug-in unit"      then 'HueZLLOnOffLight'
        when "Dimmable light"           then 'HueZLLDimmableLight'
        when "Color temperature light"  then 'HueZLLColorTempLight'
        when "Color light"              then 'HueZLLColorLight'
        when "Extended color light"     then 'HueZLLExtendedColorLight'
        else null

  class HueZLLOnOffLight extends env.devices.SwitchActuator
    HueClass: huebase.BaseHueLight

    _reachable: null

    template: "huezllonoff"

    constructor: (@config, @plugin) ->
      @id = @config.id
      @name = if @config.name.length isnt 0 then @config.name else "#{@constructor.name}_#{@id}"
      @extendAttributesActions()
      super()

      @hue = new @HueClass(this, @plugin, @config.hueId)
      @hue.deviceStateCallback = @_lightStateReceived
      @plugin.hueApiAvailable.then(
        @init
      ).catch( (error) =>
        env.logger.error "Can't initialize device #{@id} because the Hue API failed to initialize: #{error.message}"
      )

    destroy: () ->
      @plugin.framework.removeListener "after init", @_cbAfterInit
      @hue.destroy()
      super()

    extendAttributesActions: () =>
      @attributes = extend (extend {}, @attributes),
        reachable:
          description: "Light is reachable?"
          type: t.boolean

    @prepareConfig: (deviceConfig) ->
      deviceConfig.name = "" unless deviceConfig.name?

    init: () =>
      if @config.polling < 0
        # Enable global polling (for all lights or groups)
        @lightStateInitialized = @hue.setupGlobalPolling(@plugin.config.polling, @plugin.config.retries * 8)
      else
        @lightStateInitialized = @hue.setupPolling(@config.polling, @plugin.config.retries * 8)
      @lightStateInitialized.then(@_replaceName) if @config.name.length is 0
      # Ask Pimatic to wait completing init until the first poll has completed
      @_cbAfterInit = (context) =>
        context.waitForIt @lightStateInitialized
      @plugin.framework.on "after init", @_cbAfterInit

    # Wait on first poll on initialization
    waitForInit: (callback) => Promise.join @lightStateInitialized, callback

    getState: -> @waitForInit ( => @_state )
    getReachable: -> @waitForInit ( => @_reachable )

    poll: -> @hue.poll()

    saveLightState: (transitionTime=null) => @waitForInit ( =>
      hueStateChange = @hue.createStateChange @filterConflictingState @hue.getLightStatus().state
      hueStateChange.transition(transitionTime) if transitionTime?
      return hueStateChange
    )

    restoreLightState: (stateChange) =>
      return @hue.changeHueState(stateChange).then( => @_lightStateReceived(stateChange.payload()) )

    _lightStateReceived: (rstate) =>
      @_setState rstate.on
      @_setReachable rstate.reachable
      return rstate

    filterConflictingState: (state) -> state

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

    init: () =>
      if @config.hueId is 0
        # Group 0 (all lights) can't be polled
        @lightStateInitialized = Promise.resolve(true)
      else
        super()

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
      @_setCt rstate.ct if rstate.ct? and rstate.ct > 0
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
      @_setCt rstate.ct if rstate.ct? and rstate.ct > 0
      return rstate

  extend HueZLLExtendedColorLight.prototype, ColorTempMixin
  extend HueZLLExtendedColorLight.prototype, ColormodeMixin

  class HueZLLExtendedColorLightGroup extends HueZLLExtendedColorLight
    HueClass: huebase.BaseHueLightGroup
  
  extend HueZLLExtendedColorLightGroup.prototype, ColorTempMixin
  extend HueZLLExtendedColorLightGroup.prototype, ColormodeMixin

  class HueZLLScenes extends env.devices.ButtonsDevice
    _lastActivatedScene: null

    constructor: (@config, @plugin) ->
      @extendAttributesActions()

      for b in @config.buttons
        if not b.text? then b.text = b.id
      super(@config)

      @hue = new huebase.BaseHueScenes(this, @plugin)
      @plugin.hueApiAvailable.then(
        @init
      ).catch( (error) =>
        env.logger.error "Can't initialize device #{@id} because the Hue API failed to initialize: #{error.message}"
      )

    destroy: () ->
      @plugin.framework.removeListener "after init", @_cbAfterInit
      @hue.destroy()
      super()

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

    init: () =>
      scenesRetrieved = @hue.requestScenes(@plugin.config.retries * 8).then( =>
        env.logger.info "Retrieved #{Object.keys(@hue.scenesByName).length} unique scenes from the Hue API:",
          ('"'+name+'"' for name in @getKnownSceneNames()).join(', ')
      )
      # Ask Pimatic to wait completing init until the scenes have been retrieved
      @_cbAfterInit = (context) =>
        context.waitForIt scenesRetrieved
      @plugin.framework.on "after init", @_cbAfterInit

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

    buttonPressed: (buttonId) =>
      return super(buttonId).then( =>
        @hue.lookupSceneUniqueNameByNameId(buttonId).then(@activateScene)
      ).catch( (error) =>
        env.logger.debug error.message
        throw new Error("Unknown scene name id #{buttonId}")
      )


  return new HueZLLPlugin()