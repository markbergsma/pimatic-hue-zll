### 0.3.0
* Support Pimatic 0.9 auto-discovery features:
  * Automatic discovery of the Hue bridge
  * Registration (API key) of pimatic-hue-zll with the Hue bridge using the link button
  * Automatic discovery of Hue lights and light groups
* Allow device configuration to be edited from the Pimatic GUI in Pimatic 0.9
* Add ``debug`` plugin configuration option to allow plugin-specific debug messages in Pimatic 0.9

### 0.2.1
* Allow a space before the K (Kelvin) in the set color temperature action
* Fix bug where pimatic-hue-zll would keep spamming the log and need a restart to work properly again after connection loss in some circumstances (issues #7, #10)
* Resolve erroneous addition of 'name' plugin config property since Pimatic 0.8.103 (issue #8)
* Fix bug with restoration of light state for OnOff and Dimmable lights (rule actions with "for X time")

### 0.2.0
* Basic support for Hue scene activation with the HueZLLScenes device and "activate hue scene" rule action
* Add optional "transition time" parameter to light state change rule actions as well as the REST API, to control the speed/duration of the change
* Many changes under the hood w.r.t. Hue API error handling: most actions are retried a configurable amount of times on failure and transient errors are hidden
* Restore the full original light state after "... for X time" rule actions
* Fix method invocations on undefined elements in the UI
* Fix scoping bug in color temperature action

### 0.1.1
* Fix ``set ct of`` rules with the ``for X <time>`` suffix
* Add CSS rules for better layout on small screen/mobile devices (thanks to Wiebe Nieuwenhuis)
* Catch errors from UI input control methods
* Send only one Pimatic REST API request at a time from the color picker
* Improve behaviour of the color picker
* Implement polling for all lights and all groups in a single Hue API request
* Send all Hue API requests through a FIFO queue with configurable concurrency and maximum queue length

### 0.1.0
Initial release.
