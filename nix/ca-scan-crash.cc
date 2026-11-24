// goonix: crash without relying on PATH in the helper's empty environment.
#include <csignal>
int main() { raise(SIGSEGV); return 2; }
