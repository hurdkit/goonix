// goonix: graph response parser declarations using no store-local aliases.
#pragma once
#include <cstddef>
#include <list>
#include <string>

namespace nix {
bool parseGoonixGraphResponse(const std::string & input, bool eof, size_t maximum,
    std::list<std::string> & fields, unsigned int & nrHints, std::string & error);
}
