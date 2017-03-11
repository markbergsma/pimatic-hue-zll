# pimatic-hue-zll

Integration of Pimatic with (Zigbee Light Link based) Philips Hue networks, using the Philips Hue (bridge) API.

This plugin allows control of Philips Hue lights and other Zigbee Light Link (ZLL) based devices from Pimatic, and the status of Hue devices can be observed and used as events for Pimatic rules interacting with other devices. Hue scenes that were created on the Hue bridge (by other apps) can be activated from Pimatic rules.

The Hue system supports 5 light types, which have counterparts in the ZLL specification:

* On/off lights
* Dimmable lights
* Color temperature lights
* Color lights
* Extended color lights

The hue-zll plugin supports all these light types with their appropriate attributes and UI elements. Hue light groups are also supported, i.e. sets of lights that can be controlled together.

![Screenshot of Hue-ZLL plugin devices](http://saffron.wikked.net/img/huezll.png)

On/off lights have the standard on/off control integrated in Pimatic. Dimmable lights add a brightness/dimlevel slider to it while the on/off control is also retained.

For lights supporting white color temperature setting another slider is provided to select a white tone from cold to warm (in mired). Colors can be controlled as Hue & Saturation values, using a color picker.

## Installation

When you already have a working Pimatic installation, the plugin can be installed from the Pimatic UI in the Settings - Plugins menu. Or, on the command-line using npm:

```
$ npm install pimatic-hue-zll
```

## Configuration

An empty (default) configuration is enough to get started, if using Pimatic 0.9 auto-discovery and registering the plugin by pressing the Hue bridge link button within 30s on startup or discovery. The settings described below can also be adjusted from the Pimatic UI.

If you'd rather edit the `config.json` file directly, a minimal Pimatic `config.json` configuration of the hue-zll plugin with Pimatic 0.9 needs only the plugin name:

```json
  "plugins": [
    {
      "plugin": "hue-zll"
	}
  ]
```

pimatic-hue-zll will attempt auto-discovery of the bridge on startup or when initiating device discovery. If the link button on the Hue bridge has been pressed in the last 30s, this allows the plugin to register itself with the bridge.

Alternatively, the hostname or IP address of the Hue bridge, and the API username (API key) can be manually configured:

```json
  "plugins": [
    {
      "plugin": "hue-zll",
      "host": "192.168.20.9",
      "username": "17c5741c694985c90f60aabda29c4a37"
    }
  ]
```

Optionally, you can enable debugging (``debug``), specify a different TCP port number (``port``), a timeout for Hue API commands (``timeout``, default: 500ms), a maximum amount of concurrent Hue API requests (``hueApiConcurrency``, default: 1) and the number of times a Hue API request will be retried on transient errors (``retries``, default: 1). A different polling interval (from the default 5s) for retrieving the latest Hue device status from the bridge:

```json
      "debug": false,
      "port": 8080,
      "polling": 10000,
      "timeout": 2000,
      "retries": 3,
      "hueApiConcurrency": 2
```

If you get error messages like:
```Hue API maximum queue length (11) exceeded```
it means that the plugin can't send API requests to the Hue bridge fast enough (it uses a FIFO queue with configurable concurrency, see above). That's probably not a good sign, but you can override the maximum queue length from the auto calculated default if you wish:

```json
      "hueApiQueueMaxLength": 30
```

### Device configuration

Since Pimatic 0.9 and pimatic-hue-zll 0.3.0, automatic discovery of devices (lights and light groups) is supported. In the Pimatic menu, choose Settings - Devices, and click "Discover Devices". pimatic-hue-zll will then retrieve all known lights and light groups from the Hue bridge and determine the best configuration for them, which can be overriden if needed.

#### Manual configuration

All Hue devices are added to the `devices` section in Pimatic's `config.json`, and can also be edited in the Pimatic UI in the 'Devices' menu.

At minimum the device needs to be given a unique Pimatic device id and a device class. Lights and light groups also require the Hue id as it is known by the bridge.

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

If you find that some lights are not controllable (greyed out) in the Pimatic UI even though they can be controlled fine from other Hue apps, try setting ``ignoreReachability``:

```json
      "ignoreReachability": true
```

This option is required at the moment to make Osram Lightify lights work well, and is automatically set during device discovery.

The following light device classes are available from the HueZLL plugin:

| Class name               | Description   |
| ------------------------ | ------------- |
| HueZLLOnOffLight         | a ZLL light which can only be switched on or off (e.g. Osram Lightify Plug) |
| HueZLLDimmableLight      | a light that can be dimmed as well (e.g. Philips Hue White) |
| HueZLLColorTempLight     | adds white color temperature control to a dimmable light (e.g. Philips Hue White Ambiance or Osram Lightify TW) |
| HueZLLColorLight         | a light which supports colors but not white color temperature (e.g. Philips Living Colors) |
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

The *polling interval* can also be changed per device with the ``polling`` device option, such that state changes for important devices are picked up faster than with the global polling interval of lights and groups.

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

Optionally you can specify a transition time for the change, e.g. to dim a light very slowly, and back:

```
dim hue HueLight to 0% with transition time 5s for 10s
```
(Unfortunately, currently ```dim hue``` needs to be used instead of ```dim```, to avoid conflict with the internal dim rule action in Pimatic.)

For lights supporting color temperature control, the `set ct` action is added supporting mired and Kelvin values, and you can make rule actions with expressions like:

```
set ct of HueLight to 300
set color temperature of HueLight to 2700K with transition time 1s
set color temperature of HueLight to $OtherHueLight.ct for 10s
set ct of HueLight to ($randomvar/2+153)
```

Color lights can be controlled with hue & saturation percentages using the `set color` action:

```
set color of HueLight to hue 50% and saturation 100%
set color of HueLight to sat 10% hue 0% transition 1500ms for 10s
```

Because the Hue bridge doesn't accept changes to attributes while a light is switched off, the plugin also turns on the light with each action other than on/off state changes.

## Scenes
Pimatic-Hue-ZLL has basic Hue scenes support. Scenes that are known by the Hue bridge can be activated using Pimatic rules.

First make sure a ```HueZLLScenes``` device is defined in the configuration devices section:
```json
    {
      "id": "hue_scenes",
      "class": "HueZLLScenes",
      "name": "Hue Scenes"
    },
```

Arbitrary scenes can then be recalled using the ```activate hue scene``` action, using the scene name between quotes:

```
activate hue scene "Feet up"
activate hue scene "Relax" limited to group Livingroom
activate hue scene "Energize" on group Ceiling
```
The latter two actions restricts the scene to only lights that are part of the Livingroom group, as it is known by both Pimatic and the Hue bridge.

The scene last activated by Pimatic is available in the ```lastActivatedScene``` attribute of the ```HueZLLScenes``` device. Scenes can be activated from the Pimatic REST API using the ```activateScene``` action.

## Todo
Some features and wishlist items on the todo-list are:
* Hue scenes: ~~scene activation~~ (done), UI support
* Alternative ways of setting colors (XY point support, RGB, predefined colors)
* ~~Automatically locating the Hue bridge, and bridge access registration~~ (done)

This will need upstream support:
* Zigbee sensors (notably Hue dimmer switch and Hue tap support) (not yet supported in node-hue-api)
* ~~Automatically detecting the Hue/ZLL light type~~ (done)
* ~~Automatic discovery of all available Hue lights without manual configuration~~ (done)

