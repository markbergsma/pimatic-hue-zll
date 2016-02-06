# Hue ZLL Pimatic plugin

module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  # node-hue-api needs es6-promise
  es6Promise = require 'es6-promise'
  hue = require 'node-hue-api'

  class HueZLLPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass("HueZLLOnOffLight", {
        configDef: deviceConfigDef.HueZLLOnOffLight,
        createCallback: (deviceConfig) => new HueZLLOnOffLight(deviceConfig, @hueApi, @config)
      })
      @framework.deviceManager.registerDeviceClass("HueZLLDimmableLight", {
        configDef: deviceConfigDef.HueZLLDimmableLight,
        createCallback: (deviceConfig) => new HueZLLDimmableLight(deviceConfig, @hueApi, @config)
      })

      @hueApi = new hue.HueApi(
        @config.host,
        @config.username
      )

      @hueApi.version (err, version) =>
        env.logger.info("Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}")
      @hueApi.lights (err, lights) => env.logger.debug(lights)

  class BaseHueLight

    constructor: (@device, @hueApi, @hueId) ->
      @lightState = hue.lightState.create()

    poll: ->
      env.logger.debug("Polling Hue device #{@hueId}")
      return @hueApi.lightStatus(@hueId).then(@_lightStateReceived)

    _lightStateReceived: (result) =>
      newLightState = hue.lightState.create(result.state)
      env.logger.debug("light #{@hueId} old state: #{JSON.stringify(@lightState._values)}   " +
        "new state: #{JSON.stringify(newLightState._values)}")
      @lightState = newLightState
      return result.state

    setLightState: (hueState) ->
      @hueApi.setLightState(@hueId, hueState).then( ( => @lightState = hueState) )

  class HueZLLOnOffLight extends env.devices.SwitchActuator

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      super()

      @hue = new BaseHueLight(this, @hueApi, @config.hueId)
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, super()

    poll: -> @hue.poll().then(@_lightStateReceived)

    _lightStateReceived: (rstate) => @_setState rstate.on

    changeStateTo: (state) ->
      hueState = hue.lightState.create().on(state)
      return @hue.setLightState(hueState).then( ( => @_setState state) )

  class HueZLLDimmableLight extends env.devices.DimmerActuator

    constructor: (@config, hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      super()

      @hue = new BaseHueLight(this, hueApi, @config.hueId)
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, super()
    getDimlevel: -> Promise.join @lightStateInitialized, super()

    poll: -> @hue.poll().then(@_lightStateReceived)

    _lightStateReceived: (rstate) => @_setDimlevel rstate.bri / 254 * 100

    changeStateTo: (state) ->
      hueState = hue.lightState.create().on(state)
      return @hue.setLightState(hueState).then( ( => @_setState state) )

    changeDimlevelTo: (state) ->
      hueState = hue.lightState.create().on(state != 0).bri(state / 100 * 254)
      return @hue.setLightState(hueState).then( ( => @_setDimlevel state) )

  return new HueZLLPlugin()