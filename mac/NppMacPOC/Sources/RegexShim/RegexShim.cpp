#include "RegexShim.h"

#include <boost/regex.hpp>
#include <cstdlib>
#include <cstring>
#include <string>

void* npp_regex_compile(const char* pattern, char** errorOut) {
    if (errorOut) *errorOut = nullptr;
    if (!pattern) return nullptr;
    try {
        return new boost::regex(pattern, boost::regex::perl);
    } catch (const std::exception& e) {
        if (errorOut) {
            const char* message = e.what();
            size_t length = std::strlen(message);
            char* copy = static_cast<char*>(std::malloc(length + 1));
            if (copy) std::memcpy(copy, message, length + 1);
            *errorOut = copy;
        }
        return nullptr;
    }
}

int npp_regex_search(void* regex, const char* text, long textLength, long start, long end, long* outStart, long* outEnd) {
    if (!regex || !text || start < 0 || end > textLength || start > end) return 0;
    const boost::regex& re = *static_cast<boost::regex*>(regex);
    // match_prev_avail: el texto anterior a `start` existe, así que ^, \b y los lookbehind lo
    // ven igual que Scintilla al buscar dentro de un target.
    boost::match_flag_type flags = boost::match_default;
    if (start > 0) flags |= boost::match_prev_avail;
    try {
        boost::cmatch match;
        if (!boost::regex_search(text + start, text + end, match, re, flags)) return 0;
        *outStart = static_cast<long>(match[0].first - text);
        *outEnd = static_cast<long>(match[0].second - text);
        return 1;
    } catch (const std::exception&) {
        return -1;
    }
}

void npp_regex_free(void* regex) {
    delete static_cast<boost::regex*>(regex);
}

void npp_regex_free_string(char* s) {
    std::free(s);
}
