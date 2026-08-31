#!/bin/sh
. "$(dirname "$0")/assert.sh"
. "$(dirname "$0")/fixture.sh"

fixture_setup

CMD_REPLY=""; execute_command "LIST CMD" 1
assert_contains "hlavicka s rezimem"   "$CMD_REPLY" "auth mode: TOKEN"
assert_contains "STATUS s tokenem"     "$CMD_REPLY" "HUNTER <token> STATUS"
assert_contains "obsahuje LAST"        "$CMD_REPLY" "LAST <N>"
assert_contains "obsahuje ADD TOKEN"   "$CMD_REPLY" "ADD TOKEN <novy>"
assert_contains "obsahuje AUTH TYPE"   "$CMD_REPLY" "AUTH TYPE TOKEN|SENDER"
assert_contains "znacka vzdy token"    "$CMD_REPLY" "[vzdy token]"
assert_not_contains "NEobsahuje hodnotu tokenu" "$CMD_REPLY" "tajnytoken1"

set_config_value AUTH_TYPE SENDER
AUTH_TYPE=SENDER
CMD_REPLY=""; execute_command "LIST CMD" 1
assert_contains "hlavicka SENDER"          "$CMD_REPLY" "auth mode: SENDER"
assert_contains "STATUS bez tokenu"        "$CMD_REPLY" "HUNTER STATUS"
assert_contains "AUTH TYPE porad s tokenem" "$CMD_REPLY" "HUNTER <token> AUTH TYPE"

fixture_teardown
finish
