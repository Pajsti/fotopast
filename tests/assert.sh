# tests/assert.sh - minimalni tvrzeni pro shellove testy.
# Zdrojuje se z kazdeho tests/test_*.sh.

TEST_FAILED=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        printf '  OK   %s\n' "$1"
    else
        printf '  FAIL %s\n    dostal:  %s\n    cekal:   %s\n' "$1" "$2" "$3"
        TEST_FAILED=1
    fi
}

assert_contains() {
    case "$2" in
        *"$3"*) printf '  OK   %s\n' "$1" ;;
        *) printf '  FAIL %s\n    v "%s" chybi "%s"\n' "$1" "$2" "$3"
           TEST_FAILED=1 ;;
    esac
}

assert_not_contains() {
    case "$2" in
        *"$3"*) printf '  FAIL %s\n    v "%s" nemelo byt "%s"\n' "$1" "$2" "$3"
                TEST_FAILED=1 ;;
        *) printf '  OK   %s\n' "$1" ;;
    esac
}

finish() { exit "$TEST_FAILED"; }
