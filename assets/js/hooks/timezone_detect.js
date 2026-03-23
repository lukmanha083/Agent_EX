// Detects the browser's timezone and pushes it to the LiveView on mount.
const TimezoneDetect = {
  mounted() {
    const tz = typeof Intl !== 'undefined' &&
      Intl.DateTimeFormat().resolvedOptions().timeZone
    if (tz) {
      this.pushEvent("timezone_detected", { timezone: tz })
    }
  }
}

export default TimezoneDetect
