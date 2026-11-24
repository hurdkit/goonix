// goonix: bounded graph response parser; called only after child output wakes us.
#include "build-goonix-response.hh"
#include "util.hh"

namespace nix {

bool parseGoonixGraphResponse(const string & input, bool eof, size_t maximum,
    Strings & fields, unsigned int & nrHints, string & error)
{
    try {
        if (input.size() > maximum) throw Error("answer exceeded its size limit");
        if (input.empty()) {
            if (eof) throw Error("helper died without an answer");
            return false;
        }
        std::vector<string> lines = tokenizeString<std::vector<string>>(input, "\n");
        auto incomplete = [&]() -> bool {
            if (eof) throw Error("incomplete graph response at EOF");
            return false;
        };
        if (lines.empty() || lines.front() != "goonix-records 1")
            throw Error("invalid graph response marker");
        if (lines.size() < 3) return incomplete();
        size_t pos = 1;
        unsigned int nrRecords;
        if (!string2Int(lines[pos++], nrRecords) || nrRecords > 100000)
            throw Error("invalid graph record count");
        size_t afterRecords = pos + nrRecords * 7;
        if (lines.size() <= afterRecords) return incomplete();
        if (!string2Int(lines[afterRecords], nrHints) || nrHints > 100000)
            throw Error("invalid graph hint count");
        if (lines.size() < afterRecords + 1 + nrHints * 3) return incomplete();
        if (input.back() != '\n') return incomplete();
        fields.assign(lines.begin() + pos, lines.begin() + afterRecords);
        fields.insert(fields.end(), lines.begin() + afterRecords + 1,
                      lines.begin() + afterRecords + 1 + nrHints * 3);
        return true;
    } catch (std::exception & e) {
        error = e.what();
        return false;
    }
}

}
