#include <stdio.h>
const char *fixture_marker(void) {
    return "REA_STATIC_FIXTURE_MARKER_2026";
}
int main(void) {
    puts(fixture_marker());
    return 0;
}
