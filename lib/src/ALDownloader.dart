import 'dart:io';
import 'dart:isolate';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'ALDownloaderHandlerInterface.dart';
import 'ALDownloaderPersistentFileManager.dart';
import 'ALDownloaderStatus.dart';

/// ALDownloader
class ALDownloader {
  /// Initialize
  ///
  /// It can be called actively or lazily called when [download] is called.
  static Future<void> initialize() async {
    if (!_isInitial) {
      // Initialize flutterDownloader.
      await FlutterDownloader.initialize(debug: false, ignoreSsl: true);

      // Register FlutterDownloader callback.
      FlutterDownloader.registerCallback(_downloadCallback);

      // Register the isolate communication service.
      _addIsolateNameServerPortService();

      // Extract all current tasks from database and execute the tasks that need to be executed.
      // await _loadAndTryToRunTask();

      // a dirty flag that guarantees that this scope is executed only once
      _isInitial = true;
    }
  }

  /// Download
  ///
  /// **parameters**
  ///
  /// [url] url
  ///
  /// [downloaderHandlerInterface] downloader handler interface
  ///
  /// It is an one-off interface which will be destroyed when the download succeeded/failed.
  static Future<void> download(String? url,
      {ALDownloaderHandlerInterface? downloaderHandlerInterface, showNotification = false, openFileFromNotification: false}) async {
    if (url == null) throw "ALDownloader | download error = url is null";

    if (downloaderHandlerInterface != null) {
      final aBinder =
          _ALDownloaderBinder(url, downloaderHandlerInterface, false);
      _binders.add(aBinder);
    }

    await initialize();

    var task = _getTaskFromUrl(url);

    if (task != null) {
      if (await _isShouldRemoveDataForSavedDir(
          task.savedDir, url, task.status)) {
        await _removeTaskWithoutCallHandler(task);
        task = null;
      }
    }

    if (task == null) {
      // Add a prepared task to represent placeholder.
      _addTaskOrUpdateTaskForUrl(
          url, "", _ALDownloaderInnerStatus.prepared, 0, "");

      // Get the 'physical directory path' and 'file name' of the file by url.
      final alDownloaderPathComponentModel =
          await ALDownloaderPersistentFileManager
              .lazyGetALDownloaderPathModelForUrl(url);

      final dir = alDownloaderPathComponentModel.dir;

      // Equeue a task.
      final taskId = await FlutterDownloader.enqueue(
          url: url,
          savedDir: dir,
          fileName: alDownloaderPathComponentModel.fileName,
          showNotification: showNotification,
          openFileFromNotification: openFileFromNotification);

      if (taskId != null)
        _addTaskOrUpdateTaskForUrl(
            url, taskId, _ALDownloaderInnerStatus.enqueued, 0, dir);

      debugPrint(
          "ALDownloader | a download task was generated, download status = enqueued, taskId = $taskId");
    } else if (task.status == _ALDownloaderInnerStatus.failed ||
        task.status == _ALDownloaderInnerStatus.canceled) {
      final newTaskIdForRetry =
          await FlutterDownloader.retry(taskId: task.taskId);
      if (newTaskIdForRetry != null) {
        debugPrint("ALDownloader | newTaskIdForRetry = $newTaskIdForRetry");
        _addTaskOrUpdateTaskForUrl(url, newTaskIdForRetry,
            _ALDownloaderInnerStatus.enqueued, task.progress, "");
      }
    } else if (task.status == _ALDownloaderInnerStatus.paused) {
      final newTaskIdForResume =
          await FlutterDownloader.resume(taskId: task.taskId);
      if (newTaskIdForResume != null)
        _addTaskOrUpdateTaskForUrl(url, newTaskIdForResume,
            _ALDownloaderInnerStatus.running, task.progress, "");
    } else if (task.status == _ALDownloaderInnerStatus.complete) {
      debugPrint(
          "ALDownloader | try to download downloadtaskOfUrl = $url, url is complete");
      _binders.forEach((element) {
        if (element.url == url) {
          final progressHandler =
              element.downloaderHandlerHolder.progressHandler;
          if (progressHandler != null) {
            // ignore: non_constant_identifier_names
            final int_progress = task == null ? 0 : task.progress;
            // ignore: non_constant_identifier_names
            final double_progress =
                double.tryParse(((int_progress / 100).toStringAsFixed(2))) ?? 0;
            progressHandler(double_progress);
          }

          final succeededHandler =
              element.downloaderHandlerHolder.succeededHandler;
          if (succeededHandler != null) succeededHandler();
        }
      });
      _binders
          .removeWhere((element) => element.url == url && !element.isForever);
    } else if (task.status == _ALDownloaderInnerStatus.running) {
      debugPrint(
          "ALDownloader | try to download url = $url, but url is running");
    } else if (task.status == _ALDownloaderInnerStatus.enqueued) {
      debugPrint(
          "ALDownloader | try to download url = $url, but url is enqueued");
    } else if (task.status == _ALDownloaderInnerStatus.prepared) {
      debugPrint(
          "ALDownloader | try to download url = $url, but url is prepared");
    } else {}
  }

  /// Add a downloader handler interface
  ///
  /// **parameters**
  ///
  /// [downloaderHandlerInterface] downloader handler interface
  ///
  /// It is an one-off interface which will be destroyed when the download succeeded/failed.
  ///
  /// [url] url
  static void addDownloaderHandlerInterface(
      ALDownloaderHandlerInterface? downloaderHandlerInterface, String? url) {
    if (downloaderHandlerInterface == null || url == null) return;
    final aBinder = _ALDownloaderBinder(url, downloaderHandlerInterface, false);
    _binders.add(aBinder);
  }

  /// Add a forever downloader handler interface
  ///
  /// **parameters**
  ///
  /// [downloaderHandlerInterface] downloader handler interface
  ///
  /// It is a forever interface which never is destroyed unless [removeDownloaderHandlerInterfaceForUrl] or [removeDownloaderHandlerInterfaceForAll] is called.
  ///
  /// [url] url
  static void addForeverDownloaderHandlerInterface(
      ALDownloaderHandlerInterface? downloaderHandlerInterface, String? url) {
    if (downloaderHandlerInterface == null || url == null) return;
    final aBinder = _ALDownloaderBinder(url, downloaderHandlerInterface, true);
    _binders.add(aBinder);
  }

  /// Remove downloader handler interface
  ///
  /// **parameters**
  ///
  /// [url] url
  static void removeDownloaderHandlerInterfaceForUrl(String url) =>
      _binders.removeWhere((element) => url == element.url);

  /// Remove all downloader handler interfaces
  static void removeDownloaderHandlerInterfaceForAll() => _binders.clear();

  /// Get download status
  ///
  /// **parameters**
  ///
  /// [url] url
  ///
  /// **return**
  ///
  /// [ALDownloaderStatus] download status
  static ALDownloaderStatus getDownloadStatusForUrl(String url) {
    ALDownloaderStatus alDownloaderStatus;

    try {
      final task = _getTaskFromUrl(url);
      final status = task?.status;

      if (status == null ||
          status == _ALDownloaderInnerStatus.prepared ||
          status == _ALDownloaderInnerStatus.undefined ||
          status == _ALDownloaderInnerStatus.enqueued)
        alDownloaderStatus = ALDownloaderStatus.unstarted;
      else if (status == _ALDownloaderInnerStatus.running)
        alDownloaderStatus = ALDownloaderStatus.downloading;
      else if (status == _ALDownloaderInnerStatus.paused)
        alDownloaderStatus = ALDownloaderStatus.paused;
      else if (status == _ALDownloaderInnerStatus.canceled ||
          status == _ALDownloaderInnerStatus.failed)
        alDownloaderStatus = ALDownloaderStatus.failed;
      else
        alDownloaderStatus = ALDownloaderStatus.succeeded;
    } catch (error) {
      alDownloaderStatus = ALDownloaderStatus.unstarted;
      debugPrint(
          "ALDownloader | getDownloadStatusForUrl = $url, error = $error");
    }
    return alDownloaderStatus;
  }

  /// Get download progress
  ///
  /// **parameters**
  ///
  /// [url] url
  ///
  /// **return**
  ///
  /// [double] download progress
  static double getDownloadProgressForUrl(String url) {
    double alDownloaderProgress;

    try {
      final task = _getTaskFromUrl(url);

      int progress = task == null ? 0 : task.progress;

      // ignore: non_constant_identifier_names
      alDownloaderProgress =
          double.tryParse(((progress / 100).toStringAsFixed(2))) ?? 0;
    } catch (error) {
      alDownloaderProgress = 0;
      debugPrint(
          "ALDownloader | get download progress for url = $url, error = $error");
    }
    return alDownloaderProgress;
  }

  /// Pause download
  ///
  /// The downloading download will be stopped, but the incomplete data will not be deleted.
  ///
  /// **parameters**
  ///
  /// [url] url
  static Future<void> pause(String url) async {
    assert(_isInitial,
        "ALDownloader | ALDownloader.initialize or ALDownloader.download must be called first");

    try {
      final task = _getTaskFromUrl(url);

      if (task == null) {
        debugPrint("ALDownloader | pause, url = $url, but url's task is null");
        return;
      }

      final taskId = task.taskId;
      if (task.status == _ALDownloaderInnerStatus.running) {
        if (Platform.isAndroid) {
          if (await ALDownloaderPersistentFileManager
              .isExistAbsolutePhysicalPathOfFileForUrl(url)) {
            await FlutterDownloader.pause(taskId: taskId);
          } else {
            await _removeTask(task);
          }
        } else {
          await FlutterDownloader.pause(taskId: taskId);
        }
      } else if (task.status == _ALDownloaderInnerStatus.undefined ||
          task.status == _ALDownloaderInnerStatus.enqueued) {
        await _removeTask(task);
      }
    } catch (error) {
      debugPrint("ALDownloader | pause, url = $url, error = $error");
    }
  }

  /// Pause all downloads
  ///
  /// This is a multiple of [pause], see [pause].
  static Future<void> pauseAll() async {
    final aTemp = <_ALDownloadTask>[];
    aTemp.addAll(_tasks);
    for (final task in aTemp) {
      final url = task.url;
      await pause(url);
    }
  }

  /// Cancel download
  ///
  /// The downloading download will be stopped, and the incomplete data will be deleted.
  ///
  /// **parameters**
  ///
  /// [url] url
  static Future<void> cancel(String url) async {
    assert(_isInitial,
        "ALDownloader | ALDownloader.initialize or ALDownloader.download must be called first");

    try {
      final task = _getTaskFromUrl(url);

      if (task == null) {
        debugPrint("ALDownloader | cancel, url = $url, but url's task is null");
        return;
      }

      if (task.status == _ALDownloaderInnerStatus.running ||
          task.status == _ALDownloaderInnerStatus.enqueued ||
          task.status == _ALDownloaderInnerStatus.undefined) {
        await _removeTask(task);
      }
    } catch (error) {
      debugPrint("ALDownloader | cancel, url = $url, error = $error");
    }
  }

  /// Cancel all downloads
  ///
  /// This is a multiple of [cancel], see [cancel].
  static Future<void> cancelAll() async {
    final aTemp = <_ALDownloadTask>[];
    aTemp.addAll(_tasks);
    for (final task in aTemp) {
      final url = task.url;
      await cancel(url);
    }
  }

  /// Remove download
  ///
  /// The download will be removed, and the all data will be deleted.
  ///
  /// **parameters**
  ///
  /// [url] url
  static Future<void> remove(String url) async {
    assert(_isInitial,
        "ALDownloader | ALDownloader.initialize or ALDownloader.download must be called first");

    try {
      final task = _getTaskFromUrl(url);

      if (task == null) {
        debugPrint("ALDownloader | remove, url = $url, but url's task is null");
        return;
      }

      await _removeTask(task);
    } catch (error) {
      debugPrint("ALDownloader | remove, url = $url, error = $error");
    }
  }

  /// Remove all downloads
  ///
  /// This is a multiple of [remove], see [remove].
  static Future<void> removeAll() async {
    final aTemp = <_ALDownloadTask>[];
    aTemp.addAll(_tasks);
    for (final task in aTemp) {
      final url = task.url;
      await remove(url);
    }
  }

  /// Get a completed set of key-value pairs
  ///
  /// Url and result(succeeded/failed) are added to the pool.
  ///
  /// **return**
  ///
  /// completed url and result(succeeded/failed) which the structure is [url: succeeded/failed]
  static Map<String, bool> get completedKVs {
    final Map<String, bool> aMap = {};
    try {
      _tasks.forEach((element) {
        if (element.status == _ALDownloaderInnerStatus.complete) {
          aMap[element.url] = true;
        } else if (element.status == _ALDownloaderInnerStatus.failed) {
          aMap[element.url] = false;
        }
      });
    } catch (error) {
      debugPrint("ALDownloader | get completedKVs error = $error");
    }
    return aMap;
  }

  /// Manager custom download tasks
  ///
  /// **purpose**
  ///
  /// avoid frequent I/O
  ///
  /// **discusstion**
  ///
  /// Add a task or update the [url] mapping of the existing [taskId].
  static void _addTaskOrUpdateTaskForUrl(String? url, String taskId,
      _ALDownloaderInnerStatus status, int progress, String savedDir) {
    if (url == null) {
      debugPrint(
          "ALDownloader | _addTaskOrUpdateTaskForUrl, error = url is null");
      return;
    }

    bool isExistTask = false;

    try {
      for (final element in _tasks) {
        if (element.url == url) {
          if (savedDir != "") element.savedDir = savedDir;
          element.taskId = taskId;
          element.status = status;
          element.progress = progress;
          if (!isExistTask) isExistTask = true;
        }
      }
    } catch (error) {
      debugPrint("ALDownloader | _addTaskOrUpdateTaskForUrl, error = $error");
    }

    if (!isExistTask) {
      _ALDownloadTask task = _ALDownloadTask(url);
      if (savedDir != "") task.savedDir = savedDir;
      task.taskId = taskId;
      task.status = status;
      task.progress = progress;
      _tasks.add(task);
    }
  }

  /// Register send port and receive port for [IsolateNameServer]
  ///
  /// It is used for communication between download isolate and main isolate.
  static void _addIsolateNameServerPortService() {
    IsolateNameServer.registerPortWithName(
        _receivePort.sendPort, _kDownloaderSendPort);
    _receivePort.listen((dynamic data) {
      final taskId = data[0];
      final status = data[1];
      final progress = data[2];
      _processDataFromPort(taskId, status, progress);
    });
  }

  /// The callback binded by [FlutterDownloader]
  static void _downloadCallback(
      String taskId, DownloadTaskStatus status, int progress) {
    final SendPort? send =
        IsolateNameServer.lookupPortByName(_kDownloaderSendPort);
    send?.send([taskId, status, progress]);
  }

  /// Process the [FlutterDownloader]'s callback
  static void _processDataFromPort(
      String taskId, DownloadTaskStatus status, int progress) {
    _ALDownloaderInnerStatus innerStatus = transferStatus(status);

    var task = _getTaskFromTaskId(taskId);

    if (task == null) {
      debugPrint("not found task, taskId = $taskId");
      return;
    }

    final url = task.url;

    _addTaskOrUpdateTaskForUrl(url, taskId, innerStatus, progress, "");

    // ignore: non_constant_identifier_names
    final double_progress =
        double.tryParse(((progress / 100).toStringAsFixed(2))) ?? 0;

    _callHandlerBusiness1(taskId, innerStatus, url, double_progress);

    if (innerStatus == _ALDownloaderInnerStatus.canceled ||
        innerStatus == _ALDownloaderInnerStatus.failed) {
      _tasks.remove(task);
    }

    debugPrint(
        "ALDownloader | final | _downloadCallback, taskId = $taskId, url = $url, innerStatus = $innerStatus, progress = $progress, double_progress = $double_progress");
  }
  static Future loadTasks () async {
    final tasks = await FlutterDownloader.loadTasks();
    return tasks;
  }
  static const loadAndTryToRunTask = _loadAndTryToRunTask;
  /// Load [FlutterDownloader]'s local database task to the memory cache, and attempt to execute the tasks
  static Future<void> _loadAndTryToRunTask() async {
    final tasks = await FlutterDownloader.loadTasks();
    if (tasks != null) {
      debugPrint(
          "ALDownloader | Flutterdownloader | _loadAndTryToRunTask, tasks length = ${tasks.length}");

      tasks.forEach((element) {
        debugPrint(
            "ALDownloader | Flutterdownloader | _loadAndTryToRunTask, url = ${element.url}, taskId = ${element.taskId}, status = ${element.status}");
      });

      for (final element in tasks) {
        final taskId = element.taskId;
        final url = element.url;
        final status = element.status;
        final savedDir = element.savedDir;
        final progress = element.progress;

        _ALDownloaderInnerStatus innerStatus = transferStatus(status);

        final task = _ALDownloadTask(url);
        task.savedDir = savedDir;
        task.taskId = taskId;
        task.status = innerStatus;
        task.progress = progress;
        _tasks.add(task);

        final isShouldRemoveDataForSavedDir =
            await _isShouldRemoveDataForSavedDir(savedDir, url, innerStatus);
        if (isShouldRemoveDataForSavedDir) {
          // If the task should be deleted, process it throught calling [_removeTask].
          await _removeTask(task);
        } else {
          // If the task is normal, call back initial data when initializing.
          // ignore: non_constant_identifier_names
          final double_progress =
              double.tryParse(((progress / 100).toStringAsFixed(2))) ?? 0;
          _callHandlerBusiness1(taskId, innerStatus, url, double_progress);
        }
      }
    }

    debugPrint(
        "ALDownloader | _loadAndTryToRunTask, tasks length = ${_tasks.length}");

    _tasks.forEach((element) {
      debugPrint(
          "ALDownloader | _loadAndTryToRunTask, url = ${element.url}, taskId = ${element.taskId}, status = ${element.status}");
    });
  }

  /// Process business 1 for call handler
  static void _callHandlerBusiness1(
      String taskId,
      _ALDownloaderInnerStatus innerStatus,
      String url,
      // ignore: non_constant_identifier_names
      double double_progress) {
    if (innerStatus == _ALDownloaderInnerStatus.complete) {
      _binders.forEach((element) {
        if (element.url == url) {
          final progressHandler =
              element.downloaderHandlerHolder.progressHandler;
          if (progressHandler != null) progressHandler(double_progress);

          final succeededHandler =
              element.downloaderHandlerHolder.succeededHandler;
          if (succeededHandler != null) succeededHandler();
        }
      });
    } else if (innerStatus == _ALDownloaderInnerStatus.paused) {
      _binders.forEach((element) {
        if (element.url == url) {
          if (double_progress > -0.01) {
            final progressHandler =
                element.downloaderHandlerHolder.progressHandler;
            if (progressHandler != null) progressHandler(double_progress);
          }

          final pausedHandler = element.downloaderHandlerHolder.pausedHandler;
          if (pausedHandler != null) pausedHandler();
        }
      });
    } else if (innerStatus == _ALDownloaderInnerStatus.canceled ||
        innerStatus == _ALDownloaderInnerStatus.failed) {
      _binders.forEach((element) {
        if (element.url == url) {
          final progressHandler =
              element.downloaderHandlerHolder.progressHandler;
          if (progressHandler != null) progressHandler(-0.01);

          final failedHandler = element.downloaderHandlerHolder.failedHandler;
          if (failedHandler != null) failedHandler();
        }
      });
    } else if (innerStatus == _ALDownloaderInnerStatus.running) {
      _binders.forEach((element) {
        if (element.url == url) {
          final progressHandler =
              element.downloaderHandlerHolder.progressHandler;
          if (progressHandler != null) progressHandler(double_progress);
        }
      });
    }

    if (innerStatus == _ALDownloaderInnerStatus.complete ||
        innerStatus == _ALDownloaderInnerStatus.failed ||
        innerStatus == _ALDownloaderInnerStatus.canceled) {
      _binders
          .removeWhere((element) => element.url == url && !element.isForever);
    }
  }

  /// Verify the savedDir to determine whether to delete data
  static Future<bool> _isShouldRemoveDataForSavedDir(
      String savedDir, String url, _ALDownloaderInnerStatus status) async {
    if (status == _ALDownloaderInnerStatus.prepared) return false;
    if (!(await ALDownloader._isInRootPathForPath(savedDir))) return true;
    if (status == _ALDownloaderInnerStatus.complete) {
      final aBool = await ALDownloaderPersistentFileManager
          .isExistAbsolutePhysicalPathOfFileForUrl(url);
      return !aBool;
    } else {
      return false;
    }
  }

  /// Whether path is in root path
  static Future<bool> _isInRootPathForPath(String path) async {
    if (path == "") return false;

    // for deleting old version's data
    if (path.contains("/flutter/al_")) return false;

    final isSavedDirInRootPath =
        await ALDownloaderPersistentFileManager.isInRootPathWithPath(path);

    return isSavedDirInRootPath;
  }

  /// Get task from custom download tasks by [url]
  static _ALDownloadTask? _getTaskFromUrl(String url) {
    _ALDownloadTask? task;
    try {
      task = _tasks.firstWhere((element) => url == element.url);
    } catch (error) {
      debugPrint("ALDownloader | _getTaskFromUrl, error = $error");
    }
    return task;
  }

  /// Get task id from custom download tasks by [url]
  // ignore: unused_element
  static String? _getTaskIdFromUrl(String url) {
    String? taskId;
    try {
      taskId = _tasks.firstWhere((element) => url == element.url).taskId;
    } catch (error) {
      debugPrint("ALDownloader | _getTaskIdWith, error = $error");
    }
    return taskId;
  }

  /// Get task from custom download tasks by [taskId]
  // ignore: unused_element
  static _ALDownloadTask? _getTaskFromTaskId(String taskId) {
    _ALDownloadTask? task;
    try {
      task = _tasks.firstWhere((element) => taskId == element.taskId);
    } catch (error) {
      debugPrint("ALDownloader | _getTaskFromTaskId, error = $error");
    }
    return task;
  }

  /// Get url from custom download tasks by [taskId]
  // ignore: unused_element
  static String? _getUrlWithTaskId(String taskId) {
    String? url;
    try {
      url = _tasks.firstWhere((element) => taskId == element.taskId).url;
    } catch (error) {
      debugPrint("ALDownloader | _getUrlWithTaskId, error = $error");
    }
    return url;
  }

  static Future<void> _removeTask(_ALDownloadTask task) async {
    final taskId = task.taskId;
    final url = task.url;

    _binders.forEach((element) {
      if (element.url == url) {
        final progressHandler = element.downloaderHandlerHolder.progressHandler;
        if (progressHandler != null) progressHandler(-0.01);

        final failedHandler = element.downloaderHandlerHolder.failedHandler;
        if (failedHandler != null) failedHandler();
      }
    });

    _binders.removeWhere((element) => element.url == url && !element.isForever);

    await FlutterDownloader.remove(taskId: taskId, shouldDeleteContent: true);
    _tasks.remove(task);
  }

  static Future<void> _removeTaskWithoutCallHandler(
      _ALDownloadTask task) async {
    final taskId = task.taskId;
    await FlutterDownloader.remove(taskId: taskId, shouldDeleteContent: true);
    _tasks.remove(task);
  }

  static _ALDownloaderInnerStatus transferStatus(DownloadTaskStatus status) {
    if (status == DownloadTaskStatus.enqueued) {
      return _ALDownloaderInnerStatus.enqueued;
    } else if (status == DownloadTaskStatus.running) {
      return _ALDownloaderInnerStatus.running;
    } else if (status == DownloadTaskStatus.complete) {
      return _ALDownloaderInnerStatus.complete;
    } else if (status == DownloadTaskStatus.failed) {
      return _ALDownloaderInnerStatus.failed;
    } else if (status == DownloadTaskStatus.canceled) {
      return _ALDownloaderInnerStatus.canceled;
    } else if (status == DownloadTaskStatus.paused) {
      return _ALDownloaderInnerStatus.paused;
    }

    return _ALDownloaderInnerStatus.undefined;
  }

  /// A dirty flag that guarantees that this scope is executed only once
  static bool _isInitial = false;

  /// Custom download tasks
  static final List<_ALDownloadTask> _tasks = [];

  /// A binder list for binding element such as url, download ininterface, forever flag and so on
  static final List<_ALDownloaderBinder> _binders = [];

  /// Send port key
  static final _kDownloaderSendPort = "al_downloader_send_port";

  /// Receive port
  static final ReceivePort _receivePort = ReceivePort();

  /// Privatize constructor
  ALDownloader._();
}

/// A class of custom download task
class _ALDownloadTask {
  final String url;
  String savedDir = "";

  String taskId = "";
  int progress = 0;

  _ALDownloaderInnerStatus status = _ALDownloaderInnerStatus.prepared;

  _ALDownloadTask(this.url);
}

/// A binder for binding element of url and download ininterface
///
/// It may bind more elements in the future.
class _ALDownloaderBinder {
  _ALDownloaderBinder(this.url, this.downloaderHandlerHolder, this.isForever);
  final String url;
  final ALDownloaderHandlerInterface downloaderHandlerHolder;
  final bool isForever;
}

/// An enumeration of inner status
///
/// It is used to supplement some status for [DownloadTaskStatus].
///
/// It has supplemented a status [prepared] at present and may supplement more status in the future.
enum _ALDownloaderInnerStatus {
  prepared,
  undefined,
  enqueued,
  running,
  complete,
  failed,
  canceled,
  paused
}
