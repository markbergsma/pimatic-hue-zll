module.exports = (env) ->

  Promise = env.require 'bluebird'

  M = env.matcher
  assert = env.require 'cassert'

  matchTransitionExpression = (match, callback) ->
    return match.optional( (next) =>
      next.match(" with", optional: yes)
        .match(" transition ")
        .match("time ", optional: yes)
        .matchTimeDuration(wildcard: "{duration}", type: "text", callback)
    )

  class HueZLLRestorableActionHandler extends env.actions.ActionHandler
    hasRestoreAction: -> yes

    executeRestoreAction: (@simulate) =>
      if @simulate
        return "would have restored the previous light state"
      else
        return @savedStateChange
          .then(@device.restoreLightState)
          .then( => "restored the previous light state" )

    _saveState: (transitionTime=null) ->
      # Store the (promised) current light state in case we need to restore it
      @savedStateChange = @device.saveLightState(transitionTime)
      return @savedStateChange

  class CtActionProvider extends env.actions.ActionProvider
    constructor: (@framework) ->

    parseAction: (input, context) ->
      ctLights = (device for own id, device of @framework.deviceManager.devices \
                         when device.hasAction("changeCtTo"))
      return if ctLights?.length is 0

      device = null
      valueTokens = null
      kelvin = false
      match = M(input, context)
        .match(["set color temperature of ", "set ct of "])
        .matchDevice(ctLights, (next, d) =>
          if device? and device.id isnt d.id
            context?.addError(""""#{input.trim()}" is ambiguous.""")
            return
          device = d
        )
        .match(" to ")
        .matchNumericExpression( (next, ts) => valueTokens = ts )
        .match('K', optional: yes, ( => kelvin = true ))

      # optional "transition 5s"
      transitionMs = null
      match = matchTransitionExpression(match, (m, {time, unit, timeMs}) =>
        transitionMs = timeMs
      )

      unless match? and valueTokens? then return null

      if match? and valueTokens?.length is 1 and not isNaN(valueTokens[0])
        value = parseFloat(valueTokens[0])
        if kelvin and value > 0
          value = 1000000 / value
        unless 153 <= value <= 500
          context?.addError("Color temperature should be between 153 and 500 mired, or 2000 and 6535 K")
          return null
      else if valueTokens?.length > 0
        value = valueTokens
      else
        return null

      return {
        token: match.getFullMatch()
        nextInput: input.substring(match.getFullMatch().length)
        actionHandler: new CtActionHandler(@framework, device, value, transitionMs)
      }

  class CtActionHandler extends HueZLLRestorableActionHandler
    constructor: (@framework, @device, @expr, @transitionTime=null) ->
      assert @device?
      assert @expr?

    executeAction: (@simulate) =>
      # First evaluate an expression into a value if needed
      if @expr? and isNaN(@expr)
        ctValue = @framework.variableManager.evaluateExpression(@expr)
      else
        ctValue = Promise.resolve @expr

      return Promise.join ctValue, @_saveState(@transitionTime),
        ( (ct) =>
          if @simulate
            return "would have changed color temperature to #{ct} mired"
          else
            return @device.changeCtTo(ct, @transitionTime)
              .then( => "changed color temperature to #{ct} mired" )
        )

  class HueSatActionProvider extends env.actions.ActionProvider
    constructor: (@framework) ->

    parseAction: (input, context) ->
      colorLights = (device for own id, device of @framework.deviceManager.devices \
                         when device.hasAction("changeHueSatTo"))
      return if colorLights?.length is 0

      hueValueTokens = null
      satValueTokens = null
      device = null

      hueMatcher = (next) =>
        next.match(" hue ")
          .matchNumericExpression( (next, ts) => hueValueTokens = ts )
          .match('%', optional: yes)
      satMatcher = (next) =>
        next.match([" sat ", " saturation "])
          .matchNumericExpression( (next, ts) => satValueTokens = ts )
          .match('%', optional: yes)

      match = M(input, context)
        .match("set color of ")
        .matchDevice(colorLights, (next, d) =>
          if device? and device.id isnt d.id
            context?.addError(""""#{input.trim()}" is ambiguous.""")
            return
          device = d
        )
        .match(" to")
        .or([
          ( (next) =>
            hueMatcher(next)
              .optional( (next) =>
                satMatcher(next.match(" and", optional: yes))
              )
          ),
          ( (next) =>
            satMatcher(next)
              .optional( (next) =>
                hueMatcher(next.match(" and", optional: yes))
              )
          )
        ])

      # optional "transition 5s"
      transitionMs = null
      match = matchTransitionExpression(match, (m, {time, unit, timeMs}) =>
        transitionMs = timeMs
      )

      if not (match? and (hueValueTokens? or satValueTokens?))
        return null

      if hueValueTokens?.length is 1 and not isNaN(hueValueTokens[0])
        hueExpr = parseFloat(hueValueTokens[0])
        unless hueExpr? and (0.0 <= hueExpr <= 100.0)
          context?.addError("Hue value should be between 0% and 100%")
          return null
      else if hueValueTokens?.length > 0
        hueExpr = hueValueTokens

      if satValueTokens?.length is 1 and not isNaN(satValueTokens[0])
        satExpr = parseFloat(satValueTokens[0])
        unless satExpr? and (0.0 <= satExpr <= 100.0)
          context?.addError("Saturation value should be between 0% and 100%")
          return null
      else if satValueTokens?.length > 0
        satExpr = satValueTokens

      return {
        token: match.getFullMatch()
        nextInput: input.substring(match.getFullMatch().length)
        actionHandler: new HueSatActionHandler(@framework, device, hueExpr, satExpr, transitionMs)
      }

  class HueSatActionHandler extends HueZLLRestorableActionHandler
    constructor: (@framework, @device, @hueExpr, @satExpr, @transitionTime=null) ->
      assert @device?
      assert @hueExpr? or @satExpr?

    executeAction: (@simulate) =>
      # First evaluate an expression into a value if needed

      if @hueExpr? and isNaN(@hueExpr)
        huePromise = @framework.variableManager.evaluateExpression(@hueExpr)
      else
        huePromise = Promise.resolve @hueExpr
      if @satExpr? and isNaN(@satExpr)
        satPromise = @framework.variableManager.evaluateExpression(@satExpr)
      else
        satPromise = Promise.resolve @satExpr

      return Promise.join huePromise, satPromise, @_saveState(@transitionTime), @_changeHueSat

    _changeHueSat: (hueValue, satValue) =>
      if hueValue? and satValue?
        f = (hue, sat) => @device.changeHueSatTo hue, sat, @transitionTime
        msg = "changed color to hue #{hueValue}%% and sat #{satValue}%%"
      else if hueValue?
        f = (hue, sat) => @device.changeHueTo hue, @transitionTime
        msg = "changed color to hue #{hueValue}%%"
      else if satValue?
        f = (hue, sat) => @device.changeSatTo sat, @transitionTime
        msg = "changed color to sat #{satValue}%%"
      msg += " transition time #{@transitionTime}ms" if @transitionTime?

      if @simulate
        return Promise.resolve "would have #{msg}"
      else
        return f(hueValue, satValue).then( => msg )


  return exports = {
    CtActionProvider,
    HueSatActionProvider
  }