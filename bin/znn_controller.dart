#! /usr/bin/env dcli

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_ipify/dart_ipify.dart';
import 'package:dcli/dcli.dart';
import 'package:random_string_generator/random_string_generator.dart';
import 'package:system_info2/system_info2.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

const znnDaemon = 'znnd';
const znnSource = 'go-zenon';
const znnService = 'go-zenon.service';
const znnGithubUrl = 'https://github.com/zenon-network/go-zenon';

const goLinuxDlUrl = 'https://go.dev/dl/go1.20.3.linux-amd64.tar.gz';
const goLinuxSHA256Checksum =
    '979694c2c25c735755bf26f4f45e19e64e4811d661dd07b8c010f7a8e18adfca';

const optionDeploy = 'Deploy';
const optionStatus = 'Status';
const optionStartService = 'Start service';
const optionStopService = 'Stop service';
const optionResync = 'Resync';
const optionHelp = 'Help';
const optionQuit = 'Quit';

const znnControllerVersion = '0.0.4';

Future<void> main() async {
  var operatingSystem = Platform.operatingSystem;

  if (!Platform.isLinux) {
    print(
        '${orange('Warning!')} ZNN Node Controller is currently only supported on Linux hosts. Aborting.');
    exit(0);
  }

  _checkSuperuser();

  int numberOfProcessors = 0;
  String? loggedInUser = 'unknown user';
  int memTotal = SysInfo.getTotalVirtualMemory();

  try {
    numberOfProcessors = Platform.numberOfProcessors;
    loggedInUser = Shell.current.loggedInUser;
  } catch (e) {
    print(e.toString());
  }

  print(green('ZNN Node Controller v$znnControllerVersion'));

  print('Gathering system information ...');

  print(
      'System info:\nShell: ${green(Shell.current.name)}\nUser: ${green(loggedInUser!)}\nHost: ${green(Platform.localHostname)}\nOperating system: ${green(operatingSystem)}\nOS version: ${green(Platform.operatingSystemVersion)}\nAvailable CPU cores: ${green(numberOfProcessors.toString())}');

  print('Dart runtime: ${green(Platform.version)}');

  var ipv64json = await Ipify.ipv64();

  if (ipv64json.isNotEmpty) {
    print('IP address: ${green(ipv64json)}');
  } else {
    print('${red('Error!')} Not connected to the Internet. Please retry.');
    exit(0);
  }

  var selected =
      menu('Select an option from the ones listed above\n', options: [
    optionDeploy,
    optionStatus,
    optionStartService,
    optionStopService,
    optionResync,
    optionHelp,
    optionQuit
  ]);

  if (selected == 'Quit') {
    exit(0);
  }

  ensureDirectoriesExist();

  var znnConfigFilePath =
      '${znnDefaultDirectory.absolute.path + Platform.pathSeparator}config.json';
  var znnConfigFile = File(znnConfigFilePath);

  if (!znnConfigFile.existsSync()) {
    touch(znnConfigFilePath, create: true);
    znnConfigFile.writeAsStringSync('{}');
  }

  var configJson = _parseConfig(znnDefaultDirectory.absolute.path);

  KeyStoreManager keyStoreManager =
      KeyStoreManager(walletPath: znnDefaultWalletDirectory);

  switch (selected) {
    case optionDeploy:
      if (numberOfProcessors <= 4 && memTotal <= 4 * pow(10, 9)) {
        print(
            'Running on a machine with ${red('$numberOfProcessors core(s)')} and ${red('$memTotal GB RAM')}\nIt is recommended to have a ${green('minimum 4 cores and 4 GB RAM')} for running the $optionDeploy process');

        if (SysInfo.getFreeVirtualMemory() < 2 * pow(10, 9)) {
          print(
              '${orange('Warning!')} Insufficient free virtual memory detected. It is recommended to have at least 2 GB of free virtual memory');
        }
        if (!confirm(
            'Are you sure you want to proceed with the deployment process?',
            defaultValue: true)) {
          exit(0);
        }
      }
      print('Checking NTP service configuration ...');
      _configureNTPService();
      print('Preparing $znnService service configuration ...');
      if (_isZNNServicePresent()) {
        print('$znnService service detected');
        if (_isZNNServiceActive()) {
          _stopZNNService();
        }
      } else {
        print('$znnService service not detected');
        String pid = _getPid(znnDaemon);
        if (pid.isNotEmpty) {
          print('$znnDaemon is running, stopping it');
          var processResult =
              Process.runSync('kill', ['-9', pid], runInShell: true);
          if (processResult.exitCode != 0) {
            print('${red('Error!')} Kill failed. Aborting.');
            exit(0);
          }
        }
        _initZNNService();
      }

      if (!_installLinuxPrerequisites()) {
        return;
      }
      if (!_buildFromSource('/root/$znnSource', '/usr/local/bin/$znnDaemon')) {
        return;
      }

      bool isConfigured = false;
      File keyStoreFile = File(
          '${znnDefaultDirectory.absolute.path}${Platform.pathSeparator}wallet${Platform.pathSeparator}producer');
      if (_verifyProducerConfig(configJson)) {
        if (confirm(
            'Producer configuration detected. Continue using the existing configuration?',
            defaultValue: true)) {
          isConfigured = true;
          if (!keyStoreFile.existsSync()) {
            if (!confirm(
                'Producer key store file not detected. Do you want to create a new producer key store file and configure the Node with it?',
                defaultValue: false)) {
              isConfigured = true;
            }
          }
        }
      } else {
        if (keyStoreFile.existsSync()) {
          if (confirm(
              'Producer key store file detected. Do you want to configure the Node with it?',
              defaultValue: true)) {
            bool p = false;
            String keyStorePassword = '';
            int count = 0;
            while (!p && count < 3) {
              try {
                keyStorePassword = ask(
                    'Insert the producer key store password:',
                    hidden: true,
                    validator: Ask.all([Ask.dontCare, Ask.lengthMin(2)]));
                await keyStoreManager.readKeyStore(
                    keyStorePassword, keyStoreFile);
                p = true;
              } catch (e) {
                count++;
                print('${red('Error!')} ${3 - count} attempts left');
              }
            }
            if (count == 3) {
              print(
                  '${red('Error!')} Password verification failed 3 times. Aborting.');
              break;
            }
            Map keyStoreJson = json.decode(keyStoreFile.readAsStringSync());
            configJson['Producer'] = {
              'Index': 0,
              'KeyFilePath': 'producer',
              'Password': keyStorePassword,
              'Address': keyStoreJson['baseAddress']
            };
            isConfigured = true;
          }
        } else {
          isConfigured = false;
        }
      }
      if (!isConfigured) {
        String password = RandomStringGenerator(fixedLength: 16).generate();
        File newKeyStoreFile =
            await keyStoreManager.createNew(password, 'producer');
        print(
            'Key store file \'producer\' ${green('successfully')} created: ${newKeyStoreFile.path}');
        Map keyStoreJson = json.decode(newKeyStoreFile.readAsStringSync());
        print(
            'Use the address ${keyStoreJson['baseAddress']} to update the producing address of your Pillar. ${orange('Caution!')} It can be used only for one Pillar');
        configJson['Producer'] = {
          'Index': 0,
          'KeyFilePath': 'producer',
          'Password': password,
          'Address': keyStoreJson['baseAddress']
        };
      }
      _writeConfig(configJson, znnDefaultDirectory.absolute.path);
      _startZNNService();
      break;

    case optionStatus:
      _printServiceStatus();
      if (_verifyProducerConfig(configJson)) {
        print('Producer Node configuration:');
        print('\tIndex: ${configJson['Producer']['Index']}');
        print('\tKeyFilePath: ${configJson['Producer']['KeyFilePath']}');
        print('\tPassword: ${configJson['Producer']['Password']}');
        String producerAddress = configJson['Producer']['Address'];
        print('\tAddress: ${green(producerAddress)}');
        try {
          if (_isZNNServiceActive()) {
            final Zenon znnClient = Zenon();
            String urlOption = 'ws://127.0.0.1:$defaultWsPort';
            print('Syncing with the network ...');
            await znnClient.wsClient.initialize(urlOption, retry: false);
            int pageIndex = 0;
            PillarInfo? pillarFound;
            PillarInfoList pillarList =
                await znnClient.embedded.pillar.getAll(pageIndex: pageIndex);
            while (pillarList.list.isNotEmpty) {
              for (PillarInfo pillar in pillarList.list) {
                if (pillar.producerAddress.toString() == producerAddress) {
                  pillarFound = pillar;
                  break;
                }
              }
              pageIndex++;
              pillarList =
                  await znnClient.embedded.pillar.getAll(pageIndex: pageIndex);
            }
            Momentum? momentum = await znnClient.ledger.getFrontierMomentum();
            if (pillarFound != null) {
              print(
                  'The Pillar ${pillarFound.name} has ${green(producerAddress)} configured as the producer address and has produced ${pillarFound.currentStats.producedMomentums} momentums this epoch');
            } else {
              print(
                  'There is no Pillar registered with ${green(producerAddress)} at momentum hash ${momentum.hash} and height ${momentum.height}');
            }
            znnClient.wsClient.stop();
          } else {
            print('$znnDaemon is not running');
          }
        } catch (e) {
          print(e);
          break;
        }
      } else {
        print('Producer configuration not found');
      }
      break;

    case optionStartService:
      if (_isZNNServiceActive()) {
        print('$znnService is already active');
        break;
      } else {
        _startZNNService();
      }
      _printServiceStatus();
      print('Done');
      break;

    case optionStopService:
      if (_isZNNServiceActive()) {
        _stopZNNService();
      } else {
        print('$znnService is not active');
        break;
      }
      _printServiceStatus();
      print('Done');
      break;

    case optionHelp:
      print('Deploy - will deploy a Node with a producing key file configured');
      print('Status - will print the status of the Node');
      print('Start service - will start the service');
      print('Stop service - will stop the service');
      print('Resync - will resync the Node from genesis');
      print('Help');
      print('Quit');
      break;

    case optionResync:
      if (confirm(
          'This option will resync the Node starting from genesis. Do you want to continue?',
          defaultValue: true)) {
        bool running = false;
        if (_isZNNServiceActive()) {
          running = true;
          _stopZNNService();
        }
        await _resync();
        if (running) {
          _startZNNService();
          _printServiceStatus();
        }
      }
      break;

    default:
      break;
  }
}

Future<List<FileSystemEntity>> _getDirectoryContents(Directory directory) {
  var files = <FileSystemEntity>[];
  var completer = Completer<List<FileSystemEntity>>();
  var lister = directory.list(recursive: false);
  lister.listen((file) => files.add(file),
      onError: (e) => completer.complete(List.empty()),
      cancelOnError: true,
      onDone: () => completer.complete(files));
  return completer.future;
}

Future<void> _resync() async {
  var subDirs = await _getDirectoryContents(znnDefaultDirectory);
  for (var dir in subDirs) {
    if (dir.path.split(Platform.pathSeparator).last.compareTo('network') == 0) {
      dir.deleteSync(recursive: true);
    }
    if (dir.path.split(Platform.pathSeparator).last.compareTo('nom') == 0) {
      dir.deleteSync(recursive: true);
    }
    if (dir.path.split(Platform.pathSeparator).last.compareTo('consensus') ==
        0) {
      dir.deleteSync(recursive: true);
    }
    if (dir.path.split(Platform.pathSeparator).last.compareTo('log') == 0) {
      dir.deleteSync(recursive: true);
    }
  }
}

void _printServiceStatus() {
  print('$znnService status:\n');
  ProcessResult processResult =
      Process.runSync('systemctl', ['status', znnService], runInShell: true);

  print(processResult.stdout.toString());

  processResult = Process.runSync('/usr/local/bin/$znnDaemon', ['version'],
      runInShell: true);
  if (processResult.exitCode != 0) {
    print('${red('Error!')} $znnDaemon unavailable. Aborting.');
    exit(0);
  } else {
    print(processResult.stdout.toString());
  }
}

bool _verifyProducerConfig(Map<dynamic, dynamic> config) {
  if (!config.containsKey('Producer')) {
    return false;
  } else if config['Producer'] == null {
      return false;
  }
  if (!config['Producer'].containsKey('Index') ||
      !config['Producer'].containsKey('KeyFilePath') ||
      !config['Producer'].containsKey('Password') ||
      !config['Producer'].containsKey('Address')) {
    return false;
  }
  return true;
}

bool _installLinuxPrerequisites() {
  print('Installing Linux prerequisites ...');

  ProcessResult processResult;
  processResult = Process.runSync('git', ['version'], runInShell: true);
  if (processResult.exitCode != 0) {
    print('Git not detected, proceeding with the installation');
    Process.runSync('apt', ['-y', 'install', 'git-all'], runInShell: true);
  } else {
    print('Git installation detected: ${processResult.stdout}');
  }
  if (Process.runSync('apt', ['-y', 'install', 'linux-kernel-headers'],
              runInShell: true)
          .exitCode !=
      0) {
    print('${red('Error!')} Could not install linux-kernel-headers');
    return false;
  }
  if (Process.runSync('apt', ['-y', 'install', 'build-essential'],
              runInShell: true)
          .exitCode !=
      0) {
    print('${red('Error!')} Could not install build-essential');
    return false;
  }
  if (Process.runSync('apt', ['-y', 'install', 'wget'], runInShell: true)
          .exitCode !=
      0) {
    print('${red('Error!')} Could not install wget');
    return false;
  }

  processResult =
      Process.runSync('/usr/local/go/bin/go', ['version'], runInShell: true);

  if (processResult.exitCode != 0) {
    print('Go not detected, proceeding with the installation ...');
    print('Preparing to download Go ...');
    Process.runSync('wget', [goLinuxDlUrl],
        workingDirectory: '/root', runInShell: true);
    print('Checking Go download ...');
    if (!_verifyChecksum(
        '/root/${goLinuxDlUrl.substring(goLinuxDlUrl.lastIndexOf('/') + 1, goLinuxDlUrl.length)}',
        goLinuxSHA256Checksum)) {
      print('${red('Error!')} Checksum validation failed');
      return false;
    }
    print('Unpacking Go ...');
    Process.runSync(
        'tar',
        [
          '-xzvf',
          '/root/${goLinuxDlUrl.substring(goLinuxDlUrl.lastIndexOf('/') + 1, goLinuxDlUrl.length)}',
          '-C',
          '/usr/local/'
        ],
        runInShell: true);
    Process.runSync('/usr/local/go/bin/go', ['version'], runInShell: true)
        .stdout
        .toString();
    print('Cleaning downloaded files ...');
    Process.runSync(
        'rm',
        [
          '-rf',
          goLinuxDlUrl.substring(
              goLinuxDlUrl.lastIndexOf('/') + 1, goLinuxDlUrl.length)
        ],
        workingDirectory: '/root',
        runInShell: true);
  } else {
    print('Go installation detected: ${processResult.stdout}');
  }

  return true;
}

bool _buildFromSource(String sourcePath, String outputFile) {
  Directory goZenonDir = Directory(sourcePath);
  ProcessResult processResult;
  if (goZenonDir.existsSync()) {
    goZenonDir.deleteSync(recursive: true);
  }
  print('Preparing to clone go-zenon ...');
  processResult = Process.runSync(
      'git', ['clone', znnGithubUrl, goZenonDir.absolute.path],
      runInShell: true);
  if (processResult.exitCode != 0) {
    print(
        '${red('Error!')} Could not clone $znnGithubUrl into ${goZenonDir.path}');
    return false;
  }
  processResult = Process.runSync('/usr/local/go/bin/go',
      ['build', '-ldflags', '-s -w', '-o', outputFile, './cmd/znnd/main.go'],
      workingDirectory: goZenonDir.absolute.path, runInShell: true);
  if (processResult.exitCode != 0) {
    print('${red('Error!')} Could not build $znnSource');
    return false;
  }
  print(Process.runSync('file', ['znnd'],
          workingDirectory: '/usr/local/bin/', runInShell: true)
      .stdout
      .toString());
  return true;
}

String _getPid(String processName) {
  switch (Platform.operatingSystem) {
    default:
      ProcessResult processResult =
          Process.runSync('pgrep', [processName], runInShell: true);
      if (processResult.stderr.toString().isNotEmpty) {
        return '';
      }
      return processResult.stdout.toString();
  }
}

void _checkSuperuser() {
  if (Shell.current.isPrivilegedUser) {
    print('Running ZNN Controller with ${green('superuser privileges')}');
  } else {
    print(
        'Cannot start ZNN Controller. Some commands require ${green('superuser privileges')} in order to successfully complete. Please run again using superuser privileges');
    exit(0);
  }
}

bool _verifyChecksum(String filePath, String hash) {
  return (hash ==
      Process.runSync('shasum', ['-a', '256', filePath], runInShell: true)
          .stdout
          .toString()
          .substring(0, 64));
}

Map _parseConfig(String znnInstallationPath) {
  var config =
      File('${znnInstallationPath + Platform.pathSeparator}config.json');
  if (config.existsSync()) {
    String data = config.readAsStringSync();
    Map map = json.decode(data);
    return map;
  }
  return {};
}

String _formatJSON(Map<dynamic, dynamic> j) {
  var spaces = ' ' * 4;
  var encoder = JsonEncoder.withIndent(spaces);
  return encoder.convert(j);
}

void _writeConfig(Map config, String znnInstallationPath) {
  var configFile =
      File('${znnInstallationPath + Platform.pathSeparator}config.json');
  configFile.writeAsStringSync(_formatJSON(config));
}

bool _isZNNServicePresent() {
  File systemFile = File('/etc/systemd/system/$znnService');
  return systemFile.existsSync();
}

bool _isZNNServiceActive() {
  var processResult =
      Process.runSync('systemctl', ['is-active', znnService], runInShell: true);
  return processResult.stdout.toString().startsWith('active');
}

void _stopZNNService({int delay = 2}) {
  if (_isZNNServiceActive()) {
    print('Stopping $znnService ...');
    Process.runSync('systemctl', ['stop', znnService], runInShell: true);
    sleep(delay);
  }
}

void _disableZNNService({int delay = 2}) {
  if (_isZNNServiceActive()) {
    Process.runSync('systemctl', ['disable', znnService], runInShell: true);
    sleep(delay);
  }
}

void _reloadDaemonSystemctl({int delay = 2}) {
  Process.runSync('systemctl', ['daemon-reload'], runInShell: true);
  sleep(delay);
}

void _resetFailedSystemctl({int delay = 2}) {
  Process.runSync('systemctl', ['reset-failed'], runInShell: true);
  sleep(delay);
}

void _startZNNService({int delay = 2}) {
  if (!_isZNNServiceActive()) {
    print('Starting $znnService ...');
    Process.runSync('systemctl', ['enable', znnService], runInShell: true);
    Process.runSync('systemctl', ['start', znnService], runInShell: true);
    sleep(delay);
  }
}

void _configureNTPService() {
  if (!File('/etc/systemd/timesyncd.conf').existsSync()) {
    print('Configuring NTP service ...');
    var f = File('/etc/systemd/timesyncd.conf');
    f.writeAsStringSync('[Time]\nNTP=time.cloudflare.com');
  } else {
    var f = File('/etc/systemd/timesyncd.conf');
    var data = f.readAsStringSync();
    if (!data.contains('NTP=time.cloudflare.com')) {
      f.writeAsStringSync('[Time]\nNTP=time.cloudflare.com',
          mode: FileMode.append);
    }
  }
}

void _initZNNService() {
  print('Configuring $znnService ...');
  var f = File('/etc/systemd/system/$znnService');
  var data = '''
    [Unit]
    Description=$znnDaemon service
    After=network.target
    [Service]
    LimitNOFILE=32768
    User=root
    Group=root
    Type=simple
    SuccessExitStatus=SIGKILL 9
    ExecStart=/usr/local/bin/$znnDaemon
    ExecStop=/usr/bin/pkill -9 $znnDaemon
    Restart=on-failure
    TimeoutStopSec=10s
    TimeoutStartSec=10s
    [Install]
    WantedBy=multi-user.target
    ''';
  f.writeAsStringSync(data);
}

void _removeZNNService() {
  _stopZNNService();
  _disableZNNService();
  var znnServiceFile = File('/etc/systemd/system/$znnService');
  if (znnServiceFile.existsSync()) {
    znnServiceFile.deleteSync();
    print('$znnService has been removed');
  }
  _reloadDaemonSystemctl();
  _resetFailedSystemctl();
}
