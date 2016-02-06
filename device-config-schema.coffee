# hue-zll plugin device configuration attributes
module.exports = {
  HueZLLOnOffLight: {
    title: "Hue On/Off light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
  },
  HueZLLOnOffLightGroup: {
    title: "Hue On/Off light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
  },
  HueZLLDimmableLight: {
    title: "Hue Dimmable light"
    type: "object"
    properties:
      hueId:
        description: "The Hue API light id"
        type: "number"
  },
  HueZLLDimmableLightGroup: {
    title: "Hue Dimmable light group"
    type: "object"
    properties:
      hueId:
        description: "The Hue API group id"
        type: "number"
  }
}