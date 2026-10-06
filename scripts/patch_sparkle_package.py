"""Generate the additional package validation patch from clean locked sources."""
import argparse
import difflib
from pathlib import Path

def updates(path, original):
    if path == 'Sparkle/SUUpdateValidator.m':
        text = original.replace('#import "SPUVerifierInformation.h"', '#import "SPUVerifierInformation.h"\n#import "BeeSavePackagePolicy.h"')
        text = text.replace('    SUPublicKeys *publicKeys = _host.publicKeys;\n    SUSignatures *signatures = _signatures;',
                            '    fallbackOnCodeSigning = NO; // BeeSave requires Ed25519 without a signing fallback.\n    SUPublicKeys *publicKeys = _host.publicKeys;\n    SUSignatures *signatures = _signatures;')
        return text.replace('    NSURL *installSourceURL = [NSURL fileURLWithPath:installSource];', '''    NSURL *installSourceURL = [NSURL fileURLWithPath:installSource];
    // The Ed25519 signature and the Apple signature have independent roles.
    // Fail closed before any package/bundle installation path is selected.
    if (!_prevalidatedSignature || _validatedDownloadUsingCodeSigning ||
        !BeeSaveValidatePackage(installSourceURL, host.bundle.bundleURL,
            _verifierInformation.expectedVersion, _verifierInformation.beeSaveExpectedDisplayVersion, error)) return NO;''')
    if path in {'Sparkle/SPUVerifierInformation.h', 'Autoupdate/SPUInstallationInputData.h'}:
        return original.replace('@property (nonatomic, readonly) uint64_t expectedContentLength;',
            '@property (nonatomic, copy, nullable) NSString *beeSaveExpectedDisplayVersion;\n@property (nonatomic, readonly) uint64_t expectedContentLength;')
    if path == 'Sparkle/SPUInstallerDriver.m':
        line = next(line for line in original.splitlines(True) if 'SPUInstallationInputData *installationData = ' in line)
        return original.replace(line, line + '    installationData.beeSaveExpectedDisplayVersion = _updateItem.displayVersionString;\n')
    if path == 'Autoupdate/AppInstaller.m':
        line = next(line for line in original.splitlines(True) if 'self->_verifierInformation = [[SPUVerifierInformation alloc]' in line)
        return original.replace(line, line + '            self->_verifierInformation.beeSaveExpectedDisplayVersion = installationData.beeSaveExpectedDisplayVersion;\n')
    if path == 'Autoupdate/SPUInstallationInputData.m':
        text = original.replace('    return [self initWithRelaunchPath:', '    SPUInstallationInputData *result = [self initWithRelaunchPath:')
        line = next(line for line in text.splitlines(True) if 'SPUInstallationInputData *result = ' in line)
        text = text.replace(line, line + '''    result.beeSaveExpectedDisplayVersion = [decoder decodeObjectOfClass:NSString.class forKey:@"BeeSaveExpectedDisplayVersion"];
    return result;
''')
        return text.replace('    if (_expectedVersion != nil) {', '''    [coder encodeObject:self.beeSaveExpectedDisplayVersion forKey:@"BeeSaveExpectedDisplayVersion"];
    if (_expectedVersion != nil) {''')
    raise ValueError(path)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    paths = ['Sparkle/SUUpdateValidator.m', 'Sparkle/SPUVerifierInformation.h', 'Sparkle/SPUInstallerDriver.m',
             'Autoupdate/SPUInstallationInputData.h', 'Autoupdate/SPUInstallationInputData.m', 'Autoupdate/AppInstaller.m']
    patches = []
    for path in paths:
        original = (args.source / path).read_text()
        updated = updates(path, original)
        if updated == original: raise SystemExit('Missing patch site: ' + path)
        patches.extend(difflib.unified_diff(original.splitlines(True), updated.splitlines(True), fromfile='a/'+path, tofile='b/'+path))
    args.output.write_text(''.join(patches))
