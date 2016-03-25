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
    port:
      description: "Hue Bridge TCP port number"
      type: "integer"
      default: 80
    timeout:
      description: "Timeout (ms) for sending API requests to the Hue bridge"
      type: "integer"
      default: 5000
    retries:
      description: "Number of retries for Hue API requests on temporary errors"
      type: "integer"
      default: 1
    polling:
      description: "Default polling interval (ms)"
      type: "integer"
      default: 5000
    hueApiConcurrency:
      description: "Maximum concurrent requests to the Hue API"
      type: "integer"
      default: 1
    hueApiQueueMaxLength:
      description: "Maximum amount of requests queued for the Hue API"
      type: "integer"
      default: 0
}