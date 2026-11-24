// goonix: remain running until the runner's explicit test timeout kills us.
#include <unistd.h>
int main() { for (;;) pause(); }
