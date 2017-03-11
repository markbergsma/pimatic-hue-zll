$(document).on 'templateinit', (event) ->

  # helper function to mix in key/value pairs from another object
  extend = (obj, mixin) ->
    obj[key] = value for key, value of mixin
    obj

  class HueZLLOnOffItem extends pimatic.DeviceItem
    constructor: (templData, @device) ->
      super(templData, @device)
      @switchId = "switch-#{templData.deviceId}"
      stateAttribute = @getAttribute('state')
      reachableAttribute = @getAttribute('reachable')
      unless stateAttribute?
        throw new Error("A switch device needs a state attribute!")
      unless reachableAttribute?
        throw new Error("A Hue light needs a reachable attribute!")

      @switchState = ko.observable(if stateAttribute.value() then 'on' else 'off')
      stateAttribute.value.subscribe(@_onStateChange)
      reachableAttribute.value.subscribe(@_onReachableChange)

    afterRender: (elements) ->
      super(elements)
      @switchEle = $(elements).find('select')
      @switchEle.flipswitch(disabled: @_isUnreachable())
      state = @getAttribute('state')
      if state.labels?
        capitaliseFirstLetter = (s) -> s.charAt(0).toUpperCase() + s.slice(1)
        @switchEle.find('option[value=on]').text(capitaliseFirstLetter state.labels[0])
        @switchEle.find('option[value=off]').text(capitaliseFirstLetter state.labels[1])
      $(elements).find('.ui-flipswitch')
        .addClass('no-carousel-slide')
        .toggleClass('ui-state-disabled', @_isUnreachable())

    onSwitchChange: ->
      if @_restoringState then return
      stateToSet = (@switchState() is 'on')
      value = @getAttribute('state').value()
      if stateToSet is value
        return
      pimatic.try => @switchEle.flipswitch('disable')
      deviceAction = (if @switchState() is 'on' then 'turnOn' else 'turnOff')

      doIt = (
        if @device.config.xConfirm then confirm __("""
          Do you really want to turn %s #{@switchState()}?
        """, @device.name())
        else yes
      )

      restoreState = (if @switchState() is 'on' then 'off' else 'on')

      if doIt
        pimatic.loading "switch-on-#{@switchId}", "show", text: __("switching #{@switchState()}")
        @device.rest[deviceAction]({}, global: no)
          .done(ajaxShowToast)
          .fail( =>
            @_restoringState = true
            @switchState(restoreState)
            pimatic.try => @switchEle.flipswitch('refresh')
            @_restoringState = false
          ).always( =>
            pimatic.loading "switch-on-#{@switchId}", "hide"
            pimatic.try => @switchEle.flipswitch('enable')
          ).fail(ajaxAlertFail)
      else
        @_restoringState = true
        @switchState(restoreState)
        pimatic.try => @switchEle.flipswitch('enable')
        pimatic.try => @switchEle.flipswitch('refresh')
        @_restoringState = false

    _isUnreachable: =>
      @getAttribute('reachable').value() is false and not @getConfig('ignoreReachability')

    _disableInputs: =>
      @_isUnreachable() or (@getAttribute('state').value() is off)

    _onStateChange: (newState) =>
      @_restoringState = true
      @switchState(if newState then 'on' else 'off')
      pimatic.try => @switchEle.flipswitch('refresh')
      @_restoringState = false

    _onReachableChange: (nowReachable) =>
      pimatic.try => @switchEle.flipswitch(if nowReachable then 'enable' else 'disable')
      @switchEle?.toggleClass('ui-state-disabled', @_isUnreachable())

  class HueZLLDimmableItem extends HueZLLOnOffItem
    constructor: (templData, @device) ->
      super(templData, @device)
      @sliderBriId = "bri-#{templData.deviceId}"
      dimAttribute = @getAttribute('dimlevel')
      unless dimAttribute?
        throw new Error("A dimmer device needs a dimlevel attribute!")

      @sliderBriValue = ko.observable(if dimAttribute.value()? then dimAttribute.value() else 0)
      dimAttribute.value.subscribe( (newDimlevel) =>
        @sliderBriValue(newDimlevel)
        pimatic.try => @sliderBriEle.slider('refresh')
      )

    afterRender: (elements) ->
      super(elements)
      @sliderBriEle = $(elements).find('#' + @sliderBriId)
      @sliderBriEle.slider(disabled: @_disableInputs())
      $(elements).find('.ui-slider').addClass('no-carousel-slide')

    onSliderStop: ->
      unless parseInt(@sliderBriValue()) == parseInt(@getAttribute('dimlevel').value())
        pimatic.try => @sliderBriEle.slider('disable')
        pimatic.loading(
          "dimming-#{@sliderBriId}", "show", text: __("dimming to %s%", @sliderBriValue())
        )
        @device.rest.changeDimlevelTo( {dimlevel: parseInt(@sliderBriValue())}, global: no).done(ajaxShowToast)
        .always( =>
          pimatic.loading "dimming-#{@sliderBriId}", "hide"
          pimatic.try => @sliderBriEle.slider('enable')
        ).fail(ajaxAlertFail)

    _onStateChange: (newState) =>
      super(newState)
      pimatic.try => @sliderBriEle.slider(if @_disableInputs() then 'disable' else 'enable')

    _onReachableChange: (nowReachable) =>
      super(nowReachable)
      pimatic.try => @sliderBriEle.slider(if @_disableInputs() then 'disable' else 'enable')

  ColorTempMixin =
    _constructCtSlider: (templData) ->
      @sliderCtId = "ct-#{templData.deviceId}"
      ctAttribute = @getAttribute('ct')
      unless ctAttribute?
        throw new Error("A color temperature device needs a ct attribute!")
      @sliderCtValue = ko.observable(if ctAttribute.value()? then ctAttribute.value() else 370)
      ctAttribute.value.subscribe( (newCtlevel) =>
        @sliderCtValue(newCtlevel)
        pimatic.try => @sliderCtEle.slider('refresh')
      )

    _initCtSlider: (elements) ->
      @sliderCtEle = $(elements).find('#' + @sliderCtId)
      @sliderCtEle.slider(disabled: @_disableInputs())
      $(elements).find('.ui-slider').addClass('no-carousel-slide')

    _ctSliderStopped: ->
      unless parseInt(@sliderCtValue()) == parseInt(@getAttribute('ct').value())
        pimatic.try => @sliderCtEle.slider('disable')
        pimatic.loading(
          "colortemp-#{@sliderCtId}", "show", text: __("changing color temp to %s", @sliderCtValue())
        )
        @device.rest.changeCtTo( {ct: parseInt(@sliderCtValue())}, global: no).done(ajaxShowToast)
        .always( =>
          pimatic.loading "colortemp-#{@sliderCtId}", "hide"
          pimatic.try => @sliderCtEle.slider('enable')
        ).fail(ajaxAlertFail)

  class HueZLLColorTempItem extends HueZLLDimmableItem
    constructor: (templData, @device) ->
      super(templData, @device)
      @_constructCtSlider(templData)

    afterRender: (elements) ->
      super(elements)
      @_initCtSlider(elements)

    onSliderStop: ->
      super()
      @_ctSliderStopped()

    _onStateChange: (newState) =>
      super(newState)
      pimatic.try => @sliderCtEle.slider(if @_disableInputs() then 'disable' else 'enable')

    _onReachableChange: (nowReachable) =>
      super(nowReachable)
      pimatic.try => @sliderCtEle.slider(if @_disableInputs() then 'disable' else 'enable')

  extend HueZLLColorTempItem.prototype, ColorTempMixin

  class HueZLLColorItem extends HueZLLDimmableItem
    constructor: (templData, @device) ->
      super(templData, @device)
      @_pendingStateChange = null
      @_colorChanged = false
      hueAttribute = @getAttribute('hue')
      satAttribute = @getAttribute('sat')
      cmAttribute = @getAttribute('colormode')
      if not hueAttribute? or not satAttribute?
        throw new Error("A color device needs hue/sat attributes!")

      @hueValue = ko.observable(if hueAttribute.value()? then hueAttribute.value() else 0)
      @satValue = ko.observable(if satAttribute.value()? then satAttribute.value() else 0)
      hueAttribute.value.subscribe( (newHue) =>
        @hueValue(newHue)
        @_updateColorPicker() unless @_colorChanged
      )
      satAttribute.value.subscribe( (newSat) =>
        @satValue(newSat)
        @_updateColorPicker() unless @_colorChanged
      )
      cmAttribute.value.subscribe(@_updateColorPicker)

    afterRender: (elements) ->
      super(elements)
      @colorPickerEle = $(elements).find('.ui-colorpicker')
      @colorPicker = @colorPickerEle.find('.light-color')
      @colorPicker?.spectrum(
        color: @colorFromHueSat()
        preferredFormat: 'hsv'
        showButtons: false
        showInitial: false
        showInput: true
        showPalette: true
        showSelectionPalette: true
        hideAfterPaletteSelect: true
        localStorageKey: "spectrum.pimatic-hue-zll"
        allowEmpty: false
        disabled: @_disableInputs()
        move: (color) =>
          if @_pendingStateChange?.state() == "pending"
            @_colorChanged = true
          else
            @_changeColor(color).always(@_recheckColorPickerChanges)
      )
      $('.sp-container').addClass('ui-corner-all ui-shadow')
      @_toggleColorPickerDisable(@getAttribute('state').value())

    colorFromHueSat: =>
      if @getAttribute('colormode').value() == 'ct'
        return { h: 255, s: 0, v: 1, a: 0.5 }
      else
        hue = @getAttribute('hue').value() / 100 * 360
        sat = @getAttribute('sat').value() / 100
        # We don't want to set the brightness (dimlevel) from the color picker,
        # and it wouldn't really match anyway. Lock at 75%
        bri = .75
        return { h: hue, s: sat, v: bri }

    _updateColorPicker: =>
      pimatic.try => @colorPicker.spectrum("set", @colorFromHueSat())

    _changeColor: (color) ->
      @_colorChanged = false
      hueVal = color.toHsv()['h'] / 360 * 100
      satVal = color.toHsv()['s'] * 100

      return @_pendingStateChange = @device.rest.changeHueSatTo(
          {hue: hueVal, sat: satVal}, global: no
        ).then(ajaxShowToast, ajaxAlertFail)

    _recheckColorPickerChanges: =>
      if @_colorChanged and @colorPicker?
        # If the value changed while an API request was underway, send a new request
        # with the _current_ value
        return @_changeColor @colorPicker.spectrum('get')

    _toggleColorPickerDisable: =>
      disable = @_disableInputs()
      pimatic.try => @colorPicker.spectrum(if disable then 'disable' else 'enable')
      @colorPickerEle?.toggleClass('ui-state-disabled', disable)
      @colorPickerEle?.find(".sp-preview")?.toggleClass('ui-state-disabled', disable)

    _onStateChange: (newState) =>
      super(newState)
      @_toggleColorPickerDisable()

    _onReachableChange: (nowReachable) =>
      super(nowReachable)
      @_toggleColorPickerDisable()

  class HueZLLExtendedColorItem extends HueZLLColorItem
    constructor: (templData, @device) ->
      super(templData, @device)
      @_constructCtSlider(templData)

    afterRender: (elements) ->
      super(elements)
      @_initCtSlider(elements)

    onSliderStop: ->
      super()
      @_ctSliderStopped()

    _onStateChange: (newState) =>
      super(newState)
      pimatic.try => @sliderCtEle.slider(if @_disableInputs() then 'disable' else 'enable')

    _onReachableChange: (nowReachable) =>
      super(nowReachable)
      pimatic.try => @sliderCtEle.slider(if @_disableInputs() then 'disable' else 'enable')

  extend HueZLLExtendedColorItem.prototype, ColorTempMixin

  # register the item-classes
  pimatic.templateClasses['huezllonoff'] = HueZLLOnOffItem
  pimatic.templateClasses['huezlldimmable'] = HueZLLDimmableItem
  pimatic.templateClasses['huezllcolortemp'] = HueZLLColorTempItem
  pimatic.templateClasses['huezllcolor'] = HueZLLColorItem
  pimatic.templateClasses['huezllextendedcolor'] = HueZLLExtendedColorItem
