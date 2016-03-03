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
