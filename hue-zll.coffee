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

      @hueApi = new hue.HueApi(
        @config.host,
        @config.username
      )

      @hueApi.version (err, version) =>
        env.logger.info("Connected to bridge #{version['name']}, " +
          "API version #{version['version']['api']}, software #{version['version']['software']}")
      @hueApi.lights (err, lights) => env.logger.debug(lights)

  class HueZLLOnOffLight extends env.devices.SwitchActuator

    constructor: (@config, @hueApi, @_pluginConfig) ->
      @id = @config.id
      @name = @config.name
      super()

      @hueId = @config.hueId
      @lightStateInitialized = @poll()
      setInterval(( => @poll() ), @_pluginConfig.polling)

    # Wait on first poll on initialization
    getState: -> Promise.join @lightStateInitialized, super()

    poll: ->
      env.logger.debug("Polling Hue device #{@config.hueId}")
      @hueApi.lightStatus(@hueId).then(@_lightStateReceived)

    _lightStateReceived: (result) =>
      env.logger.debug("old state: #{@_state}   new state: #{result.state.on}")
      @_setState result.state.on

    changeStateTo: (state) ->
      hueState = hue.lightState.create().on(state)
      return @hueApi.setLightState(@hueId, hueState).then( ( => @_setState state) )

  return new HueZLLPlugin()