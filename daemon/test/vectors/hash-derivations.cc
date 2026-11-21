/* GNU Guix --- Functional package management for GNU
   GPL-3.0-or-later; see COPYING.

   This is the C++ hashDerivationModulo algorithm with its input loader
   redirected to a copied vector directory.  It never connects to a daemon or
   reads the live store. */
#include "derivations.hh"
#include "globals.hh"
#include "util.hh"
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>

namespace fs = std::filesystem;

static nix::Hash vectorHash(const fs::path &root, const nix::Path &path,
    std::map<nix::Path, nix::Hash> &cache)
{
    auto known = cache.find(path);
    if (known != cache.end()) return known->second;

    auto drv = nix::readDerivation(root / fs::path(path).filename());
    nix::Hash result;
    if (nix::isFixedOutputDrv(drv)) {
        auto const &out = drv.outputs.begin()->second;
        result = nix::hashString(nix::htSHA256, "fixed:out:"
            + out.hashAlgo + ":" + out.hash + ":" + out.path);
    } else {
        nix::DerivationInputs inputs;
        for (auto const &[input, outputs] : drv.inputDrvs)
            inputs[nix::printHash(vectorHash(root, input, cache))] = outputs;
        drv.inputDrvs = std::move(inputs);
        result = nix::hashString(nix::htSHA256, nix::unparseDerivation(drv));
    }
    cache.emplace(path, result);
    return result;
}

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    nix::settings.nixStore = "/gnu/store";
    fs::path root(argv[1]);
    std::ofstream out(argv[2]);
    std::map<nix::Path, nix::Hash> cache;
    std::vector<fs::path> files;
    for (auto const &entry : fs::directory_iterator(root))
        if (entry.path().extension() == ".drv") files.push_back(entry.path());
    std::sort(files.begin(), files.end());
    for (auto const &file : files) {
        auto path = "/gnu/store/" + file.filename().string();
        out << path << '\t' << nix::printHash(vectorHash(root, path, cache)) << '\n';
    }
}
