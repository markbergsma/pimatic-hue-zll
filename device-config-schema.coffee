# hue-zll plugin device configuration attributes
module.exports = {
  HueZLLOnOffLight: {
    title: "Hue On/Off light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
      ignoreReachability:
        description: "Ignore reachable attribute (device is always UI-controllable)"
        type: "boolean"
        default: false
  },
  HueZLLOnOffLightGroup: {
    title: "Hue On/Off light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
  },
  HueZLLDimmableLight: {
    title: "Hue Dimmable light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
      ignoreReachability:
        description: "Ignore reachable attribute (device is always UI-controllable)"
        type: "boolean"
        default: false
  },
  HueZLLDimmableLightGroup: {
    title: "Hue Dimmable light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
  },
  HueZLLColorTempLight: {
    title: "Hue Color Temperature light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
      ignoreReachability:
        description: "Ignore reachable attribute (device is always UI-controllable)"
        type: "boolean"
        default: false
  },
  HueZLLColorTempLightGroup: {
    title: "Hue Color Temperature light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
  },
  HueZLLColorLight: {
    title: "Hue Color light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
      ignoreReachability:
        description: "Ignore reachable attribute (device is always UI-controllable)"
        type: "boolean"
        default: false
  },
  HueZLLColorLightGroup: {
    title: "Hue Color light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
  },
  HueZLLExtendedColorLight: {
    title: "Hue Extended Color light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
      ignoreReachability:
        description: "Ignore reachable attribute (device is always UI-controllable)"
        type: "boolean"
        default: false
  },
  HueZLLExtendedColorLightGroup: {
    title: "Hue Extended Color light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
      transitionTime:
        description: "Transition time to a new light state (ms)"
        type: "number"
        required: false
      polling:
        description: "Polling interval for this device (ms)"
        type: "number"
        default: -1
  },
  HueZLLScenes: {
    title: "Hue scenes"
    type: "object"
    properties: {}
  }
}