fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios version

```sh
[bundle exec] fastlane ios version
```

Show the iOS marketing version and build number from ios/project.yml

### ios prepare

```sh
[bundle exec] fastlane ios prepare
```

Update iOS version/build, regenerate the project, and run simulator tests

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload a TestFlight build

### ios release

```sh
[bundle exec] fastlane ios release
```

Build and upload an App Store Connect release build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
