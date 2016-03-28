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
