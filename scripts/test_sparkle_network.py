"""Compile and run the patched Sparkle downloader, never a substituted implementation."""
import argparse
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path)
parser.add_argument('--output', type=Path, default=Path('/private/tmp/BeeSaveSparkleNetworkTests'))
args = parser.parse_args()
sparkle = args.source / 'Sparkle'
downloader = args.source / 'Downloader'
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
    '-DBUILDING_SPARKLE_SOURCES_EXTERNALLY=1', '-DBEESAVE_UPDATE_NETWORK_TESTS=1', '-DSPU_OBJC_DIRECT=', '-DSPU_OBJC_DIRECT_MEMBERS=',
    '-DSPARKLE_BUNDLE_IDENTIFIER="org.sparkle-project.Sparkle"',
    '-DSPARKLE_RELAUNCH_TOOL_NAME="Autoupdate"', '-DSPARKLE_INSTALLER_PROGRESS_TOOL_NAME="Updater"',
    '-I'+str(sparkle), '-I'+str(downloader),
    str(root / 'Tests/SparkleDownloaderTests/main.m'), str(downloader / 'SPUDownloader.m'),
    str(sparkle / 'SPUDownloadData.m'), str(sparkle / 'SPULocalCacheDirectory.m'),
    str(sparkle / 'SUConstants.m'), str(sparkle / 'SULog.m'), '-o', str(args.output)], check=True)
subprocess.run([str(args.output)], check=True)
