#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

CMD_REPLY=""
execute_command "STATUS"
assert_contains "STATUS vraci BAT" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "status"
assert_contains "STATUS je case-insensitive" "$CMD_REPLY" "BAT:"

CMD_REPLY=""
execute_command "QUALITY LOW"
assert_eq "QUALITY LOW odpoved" "$CMD_REPLY" "QUALITY SET TO LOW"
assert_eq "QUALITY LOW v pameti" "$QUALITY" "LOW"
assert_contains "QUALITY LOW v configu" "$(cat "$CONFIG_FILE")" "QUALITY=LOW"

CMD_REPLY=""
execute_command "neznamy prikaz"
assert_eq "neznamy prikaz" "$CMD_REPLY" "UNKNOWN CMD"

fixture_teardown
finish
