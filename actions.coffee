module.exports = (env) ->

  Promise = env.require 'bluebird'

  M = env.matcher
  assert = env.require 'cassert'

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

      if not match? and valueTokens? then return null

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
        actionHandler: new CtActionHandler(@framework, device, value)
      }

  class CtActionHandler extends env.actions.ActionHandler
    constructor: (@framework, @device, @expr) ->
      assert @device?
      assert @expr?

    executeAction: (simulate) =>
      # First evaluate an expression into a value if needed
      if @expr? and isNaN(@expr)
        ctValue = @framework.variableManager.evaluateExpression(@expr)
      else
        ctValue = Promise.resolve @expr

      if simulate
        return ctValue.then( (value) => "would change color temperature to #{value} mired" )
      else
        # Store the (promised) current Ct value in case we need to restore it
        @lastCt = @device.getCt()
        return ctValue.then( (value) =>
          @device.changeCtTo(value).then( => "changed color temperature to #{value} mired" )
        )

    hasRestoreAction: -> yes

  return exports = {
    CtActionProvider
  }