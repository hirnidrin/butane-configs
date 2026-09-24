#!/bin/bash
# The ${IPMI_FAN_*} placeholders are replaced by literal hex bytes at build
# time (build.sh / envsubst), so there is nothing to quote at run time.
# shellcheck disable=SC2086
# Set fan mode to full manual control, preventing BMC from overriding speed settings
/usr/bin/ipmitool raw 0x30 0x45 0x01 0x01
# Give BMC time to apply the mode change before setting target speeds
/usr/bin/sleep 20
# CPU fans
/usr/bin/ipmitool raw 0x30 0x70 0x66 0x01 0x00 ${IPMI_FAN_CPU_DUTY}
# Peripheral fans
/usr/bin/ipmitool raw 0x30 0x70 0x66 0x01 0x01 ${IPMI_FAN_PERIPHERAL_DUTY}
