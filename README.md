# pimatic-hue-zll

Integration of Pimatic with (Zigbee Link Light based) Philips Hue networks, using the Philips Hue (bridge) API.

This plugin allows control of Philips Hue lights and other Zigbee Link Light (ZLL) based devices from Pimatic, and the status of Hue devices can be observed and used as events for Pimatic rules interacting with other devices.

The Hue system supports 5 light types, which have counterparts in the ZLL specification:

* On/off lights
* Dimmable lights
* Color temperature lights
* Color lights
* Extended color lights

The hue-zll plugin supports all these light types with their appropriate attributes and UI elements. Hue light groups are also supported, i.e. sets of lights that can be controlled together.

![Screenshot of Hue-ZLL plugin devices](http://saffron.wikked.net/img/huezll.png)

On/off lights have the standard on/off control integraded in Pimatic. Dimmable lights add a brightness/dimlevel slider to it while the on/off control is also retained.

For lights supporting white color temperature setting another slider is provided to select a white tone from cold to warm (in mired). Colors can be controlled as Hue & Saturation values, using a color picker.

## Installation

When you already have a working Pimatic installation, the plugin can be installed using npm:

```
$ npm install pimatic-hue-zll
```

## Configuration

A minimal Pimatic `config.json` configuration of the hue-zll plugin needs the hostname or IP address of the Hue bridge, and an API username (API key) that is already registered with the bridge:

```json
  "plugins": [
    {
      "plugin": "hue-zll",
      "host": "192.168.20.9",
      "username": "17c5741c694985c90f60aabda29c4a37"
    }
  ]
```

Optionally, you can specify a different TCP port number, a timeout for Hue API commands (default: 500ms), a maximum amount of concurrent Hue API requests (default: 2) and a different polling interval (from the default 5s) for retrieving the latest Hue device status from the bridge:

```json
      "port": 8080,
      "polling": 10000,
      "timeout": 2000,
      "hueApiConcurrency": 2
```

### Device configuration

Currently all Hue devices need to be added to the `devices` section in Pimatic's `config.json`. At minimum the device needs to be given a unique Pimatic device id, a device class, and the Hue id as it is known by the bridge.

A (user friendly) name property is required by Pimatic as well, but if you leave it out or define it as the empty string `""`, the Hue-ZLL plugin will retrieve the light or group name from the Hue API.

With debug logging is enabled the plugin logs a list of current Hue lights and groups to the Pimatic log file on startup, which can be used to populate this section.

```json
  "devices": [
    {
      "id": "hue_color",
      "class": "HueZLLExtendedColorLight",
      "hueId": 1,
    },
    {
      "id": "hue_white",
      "class": "HueZLLDimmableLight",
      "hueId": 2,
    }
  ]
```

If you want to override the `name` property as it is displayed throughout Pimatic and in the user interface, simply specify it in the config:

```json
      "name": "Bedroom ceiling light",
```

The following device classes are available from the HueZLL plugin:

| Class name               | Description   |
| ------------------------ | ------------- |
| HueZLLOnOffLight         | a ZLL light which can only be switched on or off (e.g. Osram Lightify Plug) |
| HueZLLDimmableLight      | a light that can be dimmed as well (e.g. Philips Hue White) |
| HueZLLColorTempLight     | adds white color temperature control to a dimmable light (e.g. Osram Lightify TW) |
| HueZLLColorLight         | a light which supports colors but not white color temperature |
| HueZLLExtendedColorLight | a combination of the previous two: lights which supports colors as well as color temperature settings (e.g. Philips Hue Color) |

Currently you need to pick the appropriate device class for each light in order to get the desired UI control elements and light attributes; you can downgrade lamps if you wish (e.g. turn a Hue Color light into a HueZLLDimmableLight). The plugin won't prevent you from upgrading lamps either, but you'll likely get a lot of errors.

For these light types, matching light groups are supported as well:

* HueZLLOnOffLightGroup
* HueZLLDimmableLightGroup
* HueZLLColorTempLightGroup
* HueZLLColorLightGroup
* HueZLLExtendedColorLightGroup

These need a matching `hueId` as known by the Hue API as well, which for groups is a distinct name space from single lights.

If you'd like to change the default (400ms) *transition time* for light state changes, you can do so as well per device using the ``transitionTime`` option (in ms).

The *polling interval* can also be changed per device with the ``polling`` device option, such that state changes for important devices are picked up faster, or slower for devices that don't need it - reducing load on the Hue bridge and the system.

## Variables, actions and rules

All lights support at least the following attributes:

* `state`: whether the light is turned on or off
* `reachable`: whether the light is reachable by the bridge, and therefore controllable

Dimmable lights add:

* `dimlevel`: the level of brightness (0-100%), but 0% doesn't turn off the light!

Color temperature lights add:

* `ct`: the color temperature in mired (153-500)

Color lights have the following attributes on top of dimmable lights:

* `hue`: the color hue value, as a percentage
* `sat`: the color saturation value, as a percentage

Extended color lights combine the above two.

Color temperature lights and/or color lights support setting colors in multiple ways: by color temperature, hue & saturation or using XY points (not yet supported by this plugin). The mode last used is available read-only using the `colormode` string attribute, which can be one of: "ct", "hs", "xy".

All the above attributes can be used in predicates of rules (e.g. to fire when they change), or used in actions of other rules.

### Actions

Matching device action methods are available for the variables described above:

* `changeStateTo`
* `changeDimlevelTo`
* `changeCtTo`
* `changeHueTo`
* `changeSatTo`
* `changeHueSatTo`

These are exposed in the devices REST API.

#### Rules

For HueZLLOnOffLights and HueZLLDimmableLights (and groups) the standard actions as implemented by Pimatic for
On/Off lights and dimmable lights work:

```
turn on HueLight
toggle HueLight after 30s
dim HueLight to 20% for 1 minute
```

For lights supporting color temperature control, the `set ct` action is added supporting mired and Kelvin values, and you can make rule actions with expressions like:

```
set ct of HueLight to 300
set color temperature of HueLight to 2700K
set color temperature of HueLight to $OtherHueLight.ct for 10s
set ct of HueLight to ($randomvar/2+153)
```

Color lights can be controlled with hue & saturation percentages using the `set color` action:

```
set color of HueLight to hue 50% and saturation 100%
set color of HueLight to sat 10% hue 0% for 10s
```

Because the Hue bridge doesn't accept changes to attributes while a light is switched off, the plugin also turns on the light with each action other than on/off state changes.

## Todo
Some features and wishlist items on the todo-list are:
* Hue light scenes (scene activation, possibly UI support)
* Alternative ways of setting colors (XY point support, RGB, predefined colors)
* Automatically locating the Hue bridge, and bridge access registration

This will need upstream support:
* Zigbee sensors (notably Hue dimmer switch and Hue tap support) (not yet supported in node-hue-api)
* Automatically detecting the Hue/ZLL light type (needs changes in Pimatic)
* Automatic discovery of all available Hue lights without manual configuration (needs changes in Pimatic)

