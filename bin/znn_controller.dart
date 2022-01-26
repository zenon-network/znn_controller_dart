#! /usr/bin/env dcli

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_ipify/dart_ipify.dart';
import 'package:dcli/dcli.dart';
import 'package:linux_system_info/linux_system_info.dart';
import 'package:random_string_generator/random_string_generator.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

const znnDaemon = 'znnd';
const znnService = 'go-zenon.service';
const genesisFileName = 'genesis.json';
const peersFileName = 'peers.json';

const optionMigrate = 'Migrate';
const optionDeploy = 'Deploy';
const optionStatus = 'Status';
const optionStartService = 'Start service';
const optionStopService = 'Stop service';
const optionResync = 'Resync';
const optionHelp = 'Help';
const optionQuit = 'Quit';

const daemonDownloadUrl =
    'https://github.com/zenon-network/go-zenon/releases/download/v0.0.1-alphanet/$znnDaemon';

const znnControllerVersion = '0.0.1';

Future<void> main() async {
  var _operatingSystem = Platform.operatingSystem;
  var _numberOfProcessors = Platform.numberOfProcessors;
  var _loggedInUser = Shell.current.loggedInUser;
  var _memTotal = MemInfo().mem_total_gb;

  _checkSuperuser();

  print(green('ZNN Node Controller v$znnControllerVersion'));

  print('Gathering system information ...');

  print('System info:\nShell: ' +
      green(Shell.current.name) +
      '\nUser: ' +
      green(_loggedInUser!) +
      '\nHost: ' +
      green(Platform.localHostname) +
      '\nOperating system: ' +
      green(_operatingSystem) +
      '\nOS version: ' +
      green(Platform.operatingSystemVersion) +
      '\nAvailable CPU cores: ' +
      green(_numberOfProcessors.toString()));

  switch (_operatingSystem) {
    case 'linux':
      print('Linux Dart runtime: ' + green(Platform.version));
      break;
    default:
      print(
          'Operating system not supported. Only Linux is currently supported. Aborting');
      exit(0);
  }

  var _ipv64json = await Ipify.ipv64();

  if (_ipv64json.isNotEmpty) {
    print('IP address: ' + green(_ipv64json));
  } else {
    print(red('Error!') + ' Not connected to the Internet. Please retry later');
    exit(0);
  }

  var _selected =
      menu(prompt: 'Select an option from the ones listed above\n', options: [
    optionMigrate,
    optionDeploy,
    optionStatus,
    optionStartService,
    optionStopService,
    optionResync,
    optionHelp,
    optionQuit
  ]);

  if (_selected == 'Quit') {
    exit(0);
  }

  ensureDirectoriesExist();

  var _znnConfigFilePath =
      znnDefaultDirectory.absolute.path + separator + 'config.json';
  var _znnConfigFile = File(_znnConfigFilePath);

  if (!_znnConfigFile.existsSync()) {
    touch(_znnConfigFilePath, create: true);
    _znnConfigFile.writeAsStringSync('{}');
  }

  var _configJson = _parseConfig(znnDefaultDirectory.absolute.path);

  KeyStoreManager _keyStoreManager =
      KeyStoreManager(walletPath: znnDefaultWalletDirectory);

  switch (_selected) {
    case optionMigrate:
      if (_isZNNServiceActive()) {
        _stopZNNService();
      }
      await _resync();
      _downloadAndAddPeers(_configJson);
      _checkAndDownloadGenesis();
      _writeConfig(_configJson, znnDefaultDirectory.absolute.path);
      break;
    case optionDeploy:
      if (_numberOfProcessors <= 4 && _memTotal <= 4) {
        print('Running on a machine with ' +
            red(_numberOfProcessors.toString() + ' core(s)') +
            ' and ' +
            red(_memTotal.toString() + ' GB RAM') +
            '\nIt is recommended to have a ' +
            green('minimum 4 cores and 4 GB RAM') +
            ' for running a $optionDeploy');
        if (MemInfo().swap_total_gb < 2) {
          print(orange('Warning!') +
              ' Insufficient swap space detected. It is recommended to have at least 2 GB of swap space configured');
        }
        if (!confirm(
            'Are you sure you want to proceed with the deployment process?',
            defaultValue: true)) {
          exit(0);
        }
      }

      print('Checking NTP service configuration ...');

      _initNTPService();

      print('Preparing $znnService service configuration ...');

      if (_isZNNServicePresent()) {
        print('$znnService service detected');
        if (_isZNNServiceActive()) {
          _stopZNNService();
        }
      } else {
        print('$znnService service not detected');
        String _pid = _getPid(znnDaemon);
        try {
          int.parse(_pid);
          print('$znnDaemon is running, stopping it');
          var processResult =
              Process.runSync('kill', ['-9', _pid], runInShell: true);
          if (processResult.exitCode != 0) {
            print(red('Error!') + ' Kill failed. Aborting');
            exit(0);
          }
          // ignore: empty_catches
        } catch (err) {}
        _initZNNService();
      }

      _updateNodeDaemon();

      bool _isConfigured = false;
      File _keyStoreFile = File(znnDefaultDirectory.absolute.path +
          separator +
          'wallet' +
          separator +
          'producer');

      if (_verifyProducerConfig(_configJson)) {
        if (confirm(
            'Producer configuration detected. Continue using the existing configuration?',
            defaultValue: true)) {
          _isConfigured = true;
          if (!_keyStoreFile.existsSync()) {
            if (!confirm(
                'Producer key store file not detected. Do you want to create a new producer key store file and configure the Node with it?',
                defaultValue: false)) {
              _isConfigured = true;
            }
          }
        }
      } else {
        if (_keyStoreFile.existsSync()) {
          if (confirm(
              'Producer key store file detected. Do you want to configure the Node with it?',
              defaultValue: true)) {
            bool _p = false;
            String _keyStorePassword = '';
            int _count = 0;
            while (!_p && _count < 3) {
              try {
                _keyStorePassword = ask(
                    'Insert the producer key store password:',
                    hidden: true,
                    validator: Ask.all([Ask.dontCare, Ask.lengthMin(2)]));
                await _keyStoreManager.readKeyStore(
                    _keyStorePassword, _keyStoreFile);
                _p = true;
              } catch (e) {
                _count++;
                print('${red('Error!')} ${3 - _count} attempts left');
              }
            }
            if (_count == 3) {
              print('${red('Password verification failed 3 times!')} Aborting');
              break;
            }

            Map _keyStoreJson = json.decode(_keyStoreFile.readAsStringSync());
            _configJson['Producer'] = {
              'Index': 0,
              'KeyFilePath': 'producer',
              'Password': _keyStorePassword,
              'Address': _keyStoreJson['baseAddress']
            };
            _isConfigured = true;
          }
        } else {
          _isConfigured = false;
        }
      }

      if (!_isConfigured) {
        String _password = RandomStringGenerator(fixedLength: 16).generate();
        File _newKeyStoreFile =
            await _keyStoreManager.createNew(_password, 'producer');

        print(
            'Key store file \'producer\' ${green('successfully')} created: ${_newKeyStoreFile.path}');

        Map _keyStoreJson = json.decode(_newKeyStoreFile.readAsStringSync());

        print(
            'Use the address ${_keyStoreJson['baseAddress']} to update the producing address of your Pillar. ${orange('Caution!')} It can be used only for one Pillar');
        _configJson['Producer'] = {
          'Index': 0,
          'KeyFilePath': 'producer',
          'Password': _password,
          'Address': _keyStoreJson['baseAddress']
        };
      }

      _writeConfig(_configJson, znnDefaultDirectory.absolute.path);

      _startZNNService();

      break;
    case optionStatus:
      _printServiceStatus();

      if (_verifyProducerConfig(_configJson)) {
        print('Producer Node configuration:');
        print('\tIndex: ${_configJson['Producer']['Index']}');
        print('\tKeyFilePath: ${_configJson['Producer']['KeyFilePath']}');
        print('\tPassword: ${_configJson['Producer']['Password']}');
        String producerAddress = _configJson['Producer']['Address'];
        print('\tAddress: ' + green(producerAddress));

        try {
          if (_isZNNServiceActive()) {
            final Zenon znnClient = Zenon();
            String _urlOption = 'ws://127.0.0.1:$defaultWsPort';
            print('Syncing with the network ...');
            await znnClient.wsClient.initialize(_urlOption, retry: false);
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
      print('Migrate - will download Alphanet genesis and initial peers');
      print(
          'Deploy - will deploy a full node with a producing key file configured');
      print('Status - will print the status of the full node and the service');
      print('Start service - will start the service');
      print('Stop service - will stop the service');
      print('Resync - will resync the node from first momentum');
      print('Help');
      print('Quit');
      break;
    case optionResync:
      if (confirm(
          'This option will resync the full node starting from the first momentum. Do you want to continue?',
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
  String znnServiceStatus =
      Process.runSync('systemctl', ['status', znnService], runInShell: true)
          .stdout
          .toString();
  print('$znnService status:\n');
  if (znnServiceStatus.isEmpty) {
    znnServiceStatus =
        Process.runSync('systemctl', ['status', znnService], runInShell: true)
            .stderr
            .toString();
  }
  print(znnServiceStatus);
}

bool _verifyProducerConfig(Map<dynamic, dynamic> config) {
  if (!config.containsKey('Producer')) {
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

dynamic _downloadAndAddPeers(dynamic _configJson) {
  print('Preparing to download $peersFileName');
  File peersFile =
      File(znnDefaultDirectory.absolute.path + separator + peersFileName);
  if (peersFile.existsSync()) {
    peersFile.deleteSync();
  }
  var peersDownloadUrl =
      ask('Please enter the URL to download the initial peers:');
  try {
    fetch(
        url: peersDownloadUrl,
        saveToPath:
            znnDefaultDirectory.absolute.path + separator + peersFileName,
        fetchProgress: (progress) {
          switch (progress.status) {
            case FetchStatus.connected:
              print('Starting the download ...');
              break;
            case FetchStatus.error:
              print(red('Error!') + ' File not downloaded. Please retry!');
              break;
            default:
              break;
          }
        });
  } catch (e) {
    print(e);
    exit(0);
  }
  print('$peersFileName downloaded ' + green('successfully'));

  String data = peersFile.readAsStringSync();
  peersFile.deleteSync();
  var peers = json.decode(data);

  if (!peers.containsKey('Seeders')) {
    throw 'Malformed peers.json';
  }

  for (var peer in peers['Seeders']) {
    if (!_configJson.containsKey('Net')) {
      _configJson['Net'] = {'Seeders': []};
    } else if (!_configJson['Net'].containsKey('Seeders')) {
      _configJson['Net']['Seeders'] = [];
    }
    if (!_configJson['Net']['Seeders'].contains(peer)) {
      _configJson['Net']['Seeders'].add(peer);
    }
  }
}

void _checkAndDownloadGenesis() {
  print('Preparing to download $genesisFileName');

  File genesis =
      File(znnDefaultDirectory.absolute.path + separator + genesisFileName);
  if (genesis.existsSync()) {
    print('Genesis already exists');
  } else {
    var genesisDownloadUrl =
        ask('Please enter the URL to download the Alphanet genesis:');
    try {
      fetch(
          url: genesisDownloadUrl,
          saveToPath:
              znnDefaultDirectory.absolute.path + separator + genesisFileName,
          fetchProgress: (progress) {
            switch (progress.status) {
              case FetchStatus.connected:
                print('Starting the download ...');
                break;
              case FetchStatus.error:
                print(red('Error!') + ' File not downloaded. Please retry!');
                break;
              default:
                break;
            }
          });
    } catch (e) {
      print(e);
      print('Please wait for the Alphanet Big Bang timestamp');
      genesis.deleteSync();
      exit(0);
    }
    print('$genesisFileName downloaded ' + green('successfully'));
  }
}

void _downloadDaemon() {
  print('Preparing to download ' + green(znnDaemon));
  try {
    fetch(
        url: daemonDownloadUrl,
        saveToPath: '/usr/local/bin/$znnDaemon',
        fetchProgress: (progress) {
          switch (progress.status) {
            case FetchStatus.connected:
              print('Starting the download ...');
              break;
            case FetchStatus.complete:
              print('File downloaded ' + green('successfully'));
              break;
            case FetchStatus.error:
              print(red('Error!') + ' File not downloaded. Please retry!');
              break;
            default:
              break;
          }
        });
  } catch (e) {
    print('${red('Download error!')}: $e');
  }
}

void _updateNodeDaemon() {
  File _znnDaemonFile = File('/usr/local/bin/$znnDaemon');
  if (_znnDaemonFile.existsSync()) {
    _znnDaemonFile.deleteSync();
  }

  _downloadDaemon();
  if (!_znnDaemonFile.existsSync()) {
    print('There is no $znnDaemon available. Will exit now ...');
    exit(0);
  }

  print('Please check the SHA256 hash of $znnDaemon');
  print(green(Process.runSync('sha256sum', [_znnDaemonFile.absolute.path],
          runInShell: true)
      .stdout
      .toString()));

  Process.runSync('chmod', ['+x', '/usr/local/bin/$znnDaemon'],
      runInShell: true);

  print('Successfully updated: ' +
      green(Process.runSync('/usr/local/bin/$znnDaemon', ['--version'],
              runInShell: true)
          .stdout
          .toString()));
}

String _getPid(String processName) {
  switch (Platform.operatingSystem) {
    case 'linux':
      ProcessResult processResult =
          Process.runSync('pgrep', [processName], runInShell: true);
      if (processResult.stderr.toString().isNotEmpty) {
        return processResult.stderr.toString();
      }
      return processResult.stdout.toString();
    default:
      return '';
  }
}

void _checkSuperuser() {
  if (Shell.current.isPrivilegedUser) {
    print('Running with ' + green('superuser privileges'));
  } else {
    print('Some commands require ' +
        green('superuser privileges') +
        ' in order to successfully complete. Please run using superuser privileges');
    exit(0);
  }
}

bool _verifyFileHash(String hash, String filePath) {
  switch (Platform.operatingSystem) {
    case 'linux':
      return (hash ==
          Process.runSync('sha256sum', [filePath], runInShell: true)
              .stdout
              .toString());
    default:
      return false;
  }
}

Map _parseConfig(String znnInstallationPath) {
  var config = File(znnInstallationPath + separator + 'config.json');
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
  var configFile = File(znnInstallationPath + separator + 'config.json');
  configFile.writeAsStringSync(_formatJSON(config));
}

bool _isZNNServicePresent() {
  File systemFile = File('/etc/systemd/system/' + znnService);
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

void _initNTPService() {
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
