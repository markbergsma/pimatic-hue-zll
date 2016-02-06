# #hue-zll configuration options
module.exports = {
  title: "Hue ZLL config options"
  type: "object"
  properties:
    username:
      description: "Hue bridge API key/username"
      type: "string"
    host:
      description: "Hostname or IP address of the Hue bridge"
      type: "string"
    polling:
      description: "Default polling interval (ms)"
      type: "integer"
      default: 5000
}