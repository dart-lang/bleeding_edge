// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library analysis.server;

import 'dart:async';
import 'dart:collection';

import 'package:analysis_server/src/analysis_logger.dart';
import 'package:analysis_server/src/channel.dart';
import 'package:analysis_server/src/constants.dart';
import 'package:analysis_server/src/context_directory_manager.dart';
import 'package:analysis_server/src/domain_analysis.dart';
import 'package:analysis_server/src/operation/operation_analysis.dart';
import 'package:analysis_server/src/operation/operation.dart';
import 'package:analysis_server/src/operation/operation_queue.dart';
import 'package:analysis_server/src/protocol.dart';
import 'package:analysis_server/src/resource.dart';
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/sdk_io.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/generated/java_engine.dart';
import 'package:analysis_server/src/package_uri_resolver.dart';


/**
 * An instance of [DirectoryBasedDartSdk] that is shared between
 * [AnalysisServer] instances to improve performance.
 */
final DirectoryBasedDartSdk SHARED_SDK = DirectoryBasedDartSdk.defaultSdk;

class AnalysisServerContextDirectoryManager extends ContextDirectoryManager {
  final AnalysisServer analysisServer;

  AnalysisServerContextDirectoryManager(this.analysisServer, ResourceProvider resourceProvider)
      : super(resourceProvider);

  @override
  void addContext(Folder folder, File pubspecFile) {
    ContextDirectory contextDirectory = new ContextDirectory(
        analysisServer.defaultSdk, resourceProvider, folder, pubspecFile);
    analysisServer.folderMap[folder] = contextDirectory;
    analysisServer.schedulePerformAnalysisOperation(contextDirectory.context);
  }

  @override
  void applyChangesToContext(Folder contextFolder, ChangeSet changeSet) {
    AnalysisContext context = analysisServer.folderMap[contextFolder].context;
    context.applyChanges(changeSet);
    analysisServer.schedulePerformAnalysisOperation(context);
  }

  @override
  void removeContext(Folder folder) {
    analysisServer.folderMap.remove(folder);
  }
}

/**
 * Instances of the class [AnalysisServer] implement a server that listens on a
 * [CommunicationChannel] for analysis requests and process them.
 */
class AnalysisServer {
  /**
   * The channel from which requests are received and to which responses should
   * be sent.
   */
  final ServerCommunicationChannel channel;

  /**
   * [ContextDirectoryManager] which handles the mapping from analysis roots
   * to context directories.
   */
  AnalysisServerContextDirectoryManager contextDirectoryManager;

  /**
   * A flag indicating whether the server is running.  When false, contexts
   * will no longer be added to [contextWorkQueue], and [performOperation] will
   * discard any tasks it finds on [contextWorkQueue].
   */
  bool running;

  /**
   * A list of the request handlers used to handle the requests sent to this
   * server.
   */
  List<RequestHandler> handlers;

  /**
   * The current default [DartSdk].
   */
  DartSdk defaultSdk = SHARED_SDK;

  /**
   * A table mapping [Folder]s to the [ContextDirectory]s associated with them.
   */
  final Map<Folder, ContextDirectory> folderMap =
      new HashMap<Folder, ContextDirectory>();

  /**
   * A queue of the operations to perform in this server.
   *
   * Invariant: when this queue is non-empty, there is exactly one pending call
   * to [performOperation] on the event queue.  When this list is empty, there are
   * no calls to [performOperation] on the event queue.
   */
  ServerOperationQueue operationQueue;

  /**
   * A set of the [ServerService]s to send notifications for.
   */
  Set<ServerService> serverServices = new HashSet<ServerService>();

  /**
   * A table mapping [AnalysisService]s to the file paths for which these
   * notifications should be sent.
   */
  Map<AnalysisService, Set<String>> analysisServices =
      new HashMap<AnalysisService, Set<String>>();

  /**
   * True if any exceptions thrown by analysis should be propagated up the call
   * stack.
   */
  bool rethrowExceptions;

  /**
   * Initialize a newly created server to receive requests from and send
   * responses to the given [channel].
   *
   * If [rethrowExceptions] is true, then any exceptions thrown by analysis are
   * propagated up the call stack.  The default is true to allow analysis
   * exceptions to show up in unit tests, but it should be set to false when
   * running a full analysis server.
   */
  AnalysisServer(this.channel, ResourceProvider resourceProvider,
      {this.rethrowExceptions: true}) {
    operationQueue = new ServerOperationQueue(this);
    contextDirectoryManager = new AnalysisServerContextDirectoryManager(this, resourceProvider);
    AnalysisEngine.instance.logger = new AnalysisLogger();
    running = true;
    Notification notification = new Notification(SERVER_CONNECTED);
    channel.sendNotification(notification);
    channel.listen(handleRequest, onDone: done, onError: error);
  }

  /**
   * Schedules execution of the given [ServerOperation].
   */
  void scheduleOperation(ServerOperation operation) {
    bool wasEmpty = operationQueue.isEmpty;
    addOperation(operation);
    if (wasEmpty) {
      _schedulePerformOperation();
    }
  }

  /**
   * Schedules analysis of the given context.
   */
  void schedulePerformAnalysisOperation(AnalysisContext context) {
    scheduleOperation(new PerformAnalysisOperation(context, false));
  }

  /**
   * Send the given [notification] to the client.
   */
  void sendNotification(Notification notification) {
    channel.sendNotification(notification);
  }

  /**
   * Set the priority files to the given [files].
   */
  void setPriorityFiles(Request request, List<String> files) {
    Map<AnalysisContext, List<Source>> sourceMap =
        new HashMap<AnalysisContext, List<Source>>();
    List<String> unanalyzed = new List<String>();
    files.forEach((file) {
      AnalysisContext analysisContext = _getAnalysisContext(file);
      if (analysisContext == null) {
        unanalyzed.add(file);
      } else {
        List<Source> sourceList = sourceMap[analysisContext];
        if (sourceList == null) {
          sourceList = <Source>[];
          sourceMap[analysisContext] = sourceList;
        }
        sourceList.add(_getSource(file));
      }
    });
    if (unanalyzed.isNotEmpty) {
      StringBuffer buffer = new StringBuffer();
      buffer.writeAll(unanalyzed, ', ');
      throw new RequestFailure(new Response.unanalyzedPriorityFiles(request,
          buffer.toString()));
    }
    folderMap.forEach((Folder folder, ContextDirectory directory) {
      AnalysisContext context = directory.context;
      List<Source> sourceList = sourceMap[context];
      if (sourceList == null) {
        sourceList = Source.EMPTY_ARRAY;
      }
      context.analysisPriorityOrder = sourceList;
    });
  }

  /**
   * Adds the given [ServerOperation] to the queue, but does not schedule
   * operations execution.
   */
  void addOperation(ServerOperation operation) {
    operationQueue.add(operation);
  }

  /**
   * The socket from which requests are being read has been closed.
   */
  void done() {
    running = false;
  }

  /**
   * There was an error related to the socket from which requests are being
   * read.
   */
  void error(argument) {
    running = false;
  }

// TODO(brianwilkerson) Add the following method after 'prioritySources' has
// been added to InternalAnalysisContext.
//  /**
//   * Return a list containing the full names of all of the sources that are
//   * priority sources.
//   */
//  List<String> getPriorityFiles() {
//    List<String> priorityFiles = new List<String>();
//    folderMap.values.forEach((ContextDirectory directory) {
//      InternalAnalysisContext context = directory.context;
//      context.prioritySources.forEach((Source source) {
//        priorityFiles.add(source.fullName);
//      });
//    });
//    return priorityFiles;
//  }

  /**
   * Handle a [request] that was read from the communication channel.
   */
  void handleRequest(Request request) {
    int count = handlers.length;
    for (int i = 0; i < count; i++) {
      try {
        Response response = handlers[i].handleRequest(request);
        if (response != null) {
          channel.sendResponse(response);
          return;
        }
      } on RequestFailure catch (exception) {
        channel.sendResponse(exception.response);
        return;
      }
    }
    channel.sendResponse(new Response.unknownRequest(request));
  }

  /**
   * Returns `true` if there is a subscription for the given [server] and [file].
   */
  bool hasAnalysisSubscription(AnalysisService service, String file) {
    Set<String> files = analysisServices[service];
    return files != null && files.contains(file);
  }

  /**
   * Returns `true` if the given [AnalysisContext] is a priority one.
   */
  bool isPriorityContext(AnalysisContext context) {
    // TODO(scheglov) implement support for priority sources/contexts
    return false;
  }

  /**
   * Perform the next available [ServerOperation].
   */
  void performOperation() {
    if (!running) {
      // An error has occurred, or the connection to the client has been
      // closed, since this method was scheduled on the event queue.  So
      // don't do anything.  Instead clear the operation queue.
      operationQueue.clear();
      return;
    }
    // prepare next operation
    ServerOperation operation = operationQueue.take();
    // perform the operation
    try {
      operation.perform(this);
    } catch (exception, stackTrace) {
      AnalysisEngine.instance.logger.logError("${exception}\n${stackTrace}");
      if (rethrowExceptions) {
        throw new AnalysisException(
            'Unexpected exception during analysis',
            new CaughtException(exception, stackTrace));
      }
    } finally {
      if (!operationQueue.isEmpty) {
        _schedulePerformOperation();
      } else {
        sendStatusNotification(null);
      }
    }
  }

  /**
   * Send status notification to the client. The `contextId` indicates
   * the current context being analyzed or `null` if analysis is complete.
   */
  void sendStatusNotification(String contextId) {
    Notification notification = new Notification(SERVER_STATUS);
    Map<String, Object> analysis = new Map();
    if (contextId != null) {
      analysis['analyzing'] = true;
      // TODO(danrubel): replace contextId with real analysisTarget
      analysis['analysisTarget'] = contextId;
    } else {
      analysis['analyzing'] = false;
    }
    notification.params['analysis'] = analysis;
    channel.sendNotification(notification);
  }

  /**
   * Implementation for `analysis.setAnalysisRoots`.
   *
   * TODO(scheglov) implement complete projects/contexts semantics.
   *
   * The current implementation is intentionally simplified and expected
   * that only folders are given each given folder corresponds to the exactly
   * one context.
   *
   * So, we can start working in parallel on adding services and improving
   * projects/contexts support.
   */
  void setAnalysisRoots(String requestId,
                        List<String> includedPaths,
                        List<String> excludedPaths) {
    try {
      contextDirectoryManager.setRoots(includedPaths, excludedPaths);
    } on UnimplementedError catch (e) {
      throw new RequestFailure(
                  new Response.unsupportedFeature(
                      requestId, e.message));
    }
  }

  /**
   * Implementation for `analysis.updateContent`.
   */
  void updateContent(Map<String, ContentChange> changes) {
    changes.forEach((file, change) {
      AnalysisContext analysisContext = _getAnalysisContext(file);
      // TODO(paulberry): handle the case where a file is referred to by more
      // than one context (e.g package A depends on package B using a local
      // path, user has both packages open for editing in separate contexts,
      // and user modifies a file in package B).
      if (analysisContext != null) {
        Source source = _getSource(file);
        if (change.offset == null) {
          analysisContext.setContents(source, change.content);
        } else {
          analysisContext.setChangedContents(source, change.content,
              change.offset, change.oldLength, change.newLength);
        }
        schedulePerformAnalysisOperation(analysisContext);
      }
    });
  }

  /**
   * Implementation for `analysis.setSubscriptions`.
   */
  void setAnalysisSubscriptions(Map<AnalysisService, Set<String>> subscriptions) {
    // send notifications for already analyzed sources
    subscriptions.forEach((service, Set<String> newFiles) {
      Set<String> oldFiles = analysisServices[service];
      Set<String> todoFiles = oldFiles != null ? newFiles.difference(oldFiles) : newFiles;
      for (String file in todoFiles) {
        if (service == AnalysisService.ERRORS) {
          Source source = _getSource(file);
          AnalysisContext analysisContext = _getAnalysisContext(file);
          List<AnalysisError> errors = analysisContext.getErrors(source).errors;
          sendAnalysisNotificationErrors(this, file, errors);
        }
        // Dart unit notifications.
        if (AnalysisEngine.isDartFileName(file)) {
          CompilationUnit dartUnit = getResolvedCompilationUnitToResendNotification(file);
          if (dartUnit != null) {
            switch (service) {
              case AnalysisService.HIGHLIGHTS:
                sendAnalysisNotificationHighlights(this, file, dartUnit);
                break;
              case AnalysisService.NAVIGATION:
                // TODO(scheglov) consider support for one unit in 2+ libraries
                sendAnalysisNotificationNavigation(this, file, dartUnit);
                break;
              case AnalysisService.OUTLINE:
                sendAnalysisNotificationOutline(this, file, dartUnit);
                break;
            }
          }
        }
      }
    });
    // remember new subscriptions
    this.analysisServices = subscriptions;
  }

  /**
   * Return the [AnalysisContext] that is used to analyze the given [path].
   * Return `null` if there is no such context.
   */
  AnalysisContext _getAnalysisContext(String path) {
    for (Folder folder in folderMap.keys) {
      if (path.startsWith(folder.path)) {
        return folderMap[folder].context;
      }
    }
    return null;
  }

  /**
   * Return the [Source] of the Dart file with the given [path].
   */
  Source _getSource(String path) {
    File file = contextDirectoryManager.resourceProvider.getResource(path);
    return file.createSource(UriKind.FILE_URI);
  }

  /**
   * Returns the [CompilationUnit] of the Dart file with the given [path] that
   * should be used to resend notifications for already resolved unit.
   * Returns `null` if the file is not a part of any context, library has not
   * been yet resolved, or any problem happened.
   */
  CompilationUnit getResolvedCompilationUnitToResendNotification(String path) {
    // prepare AnalysisContext
    AnalysisContext context = _getAnalysisContext(path);
    if (context == null) {
      return null;
    }
    // prepare sources
    Source unitSource = _getSource(path);
    List<Source> librarySources = context.getLibrariesContaining(unitSource);
    if (librarySources.isEmpty) {
      return null;
    }
    // if library has not been resolved yet, the unit will be resolved later
    Source librarySource = librarySources[0];
    if (context.getLibraryElement(librarySource) == null) {
      return null;
    }
    // if library has been already resolved, resolve unit
    return context.resolveCompilationUnit2(unitSource, librarySource);
  }

  /**
   * Return the [CompilationUnit] of the Dart file with the given [path].
   * Return `null` if the file is not a part of any context.
   */
  CompilationUnit test_getResolvedCompilationUnit(String path) {
    // prepare AnalysisContext
    AnalysisContext context = _getAnalysisContext(path);
    if (context == null) {
      return null;
    }
    // prepare sources
    Source unitSource = _getSource(path);
    List<Source> librarySources = context.getLibrariesContaining(unitSource);
    if (librarySources.isEmpty) {
      return null;
    }
    // get a resolved unit
    return context.getResolvedCompilationUnit2(unitSource, librarySources[0]);
  }

  /**
   * Return `true` if all operations have been performed in this [AnalysisServer].
   */
  bool test_areOperationsFinished() {
    return operationQueue.isEmpty;
  }

  /**
   * Schedules [performOperation] exection.
   */
  void _schedulePerformOperation() {
    new Future(performOperation);
  }
}


/**
 * An enumeration of the services provided by the analysis domain.
 */
class AnalysisService extends Enum2<AnalysisService> {
  static const AnalysisService ERRORS = const AnalysisService('ERRORS', 0);
  static const AnalysisService HIGHLIGHTS = const AnalysisService('HIGHLIGHTS', 1);
  static const AnalysisService NAVIGATION = const AnalysisService('NAVIGATION', 2);
  static const AnalysisService OUTLINE = const AnalysisService('OUTLINE', 3);

  static const List<AnalysisService> VALUES =
      const [ERRORS, HIGHLIGHTS, NAVIGATION, OUTLINE];

  const AnalysisService(String name, int ordinal) : super(name, ordinal);
}


/**
 * Instances of [ContextDirectory] represents a [Folder] associated with an
 * analysis context.  The folder may or may not contain a Pub `pubspec.yaml`.
 *
 * TODO(scheglov) implement complete projects/contexts semantics.
 *
 * This class is intentionally simplified to serve as a base to start working
 * on services while work on complete semantics is being done in parallel.
 */
class ContextDirectory {
  /**
   * The root [ResourceProvider] of this [ContextDirectory].
   */
  final ResourceProvider _resourceProvider;

  /**
   * The root [Folder] of this [ContextDirectory].
   */
  final Folder _folder;

  /**
   * The `pubspec.yaml` file in [_folder], or null if there isn't one.
   */
  File _pubspecFile;

  /**
   * The [AnalysisContext] of this [_folder].
   */
  AnalysisContext _context;

  ContextDirectory(DartSdk sdk, this._resourceProvider, this._folder,
      this._pubspecFile) {
    // create AnalysisContext
    _context = AnalysisEngine.instance.createAnalysisContext();
    // TODO(scheglov) replace FileUriResolver with an Resource based resolver
    List<UriResolver> resolvers = <UriResolver>[new DartUriResolver(sdk),
        new FileUriResolver(),
    ];
    {
      UriResolver packageResolver = _createPackageUriResolver();
      if (packageResolver != null) {
        resolvers.add(packageResolver);
      }
    }
    _context.sourceFactory = new SourceFactory(resolvers);
  }

  /**
   * Return the [AnalysisContext] of this folder.
   */
  AnalysisContext get context => _context;

  /**
   * Returns an [UriResolver] for `package` URIs, or `null` if not a Pub
   * application.
   */
  UriResolver _createPackageUriResolver() {
    // prepare 'packages' folder
    Resource packagesResource = _folder.getChild('packages');
    if (packagesResource is! Folder) {
      return null;
    }
    Folder packagesFolder = packagesResource;
    // list packages
    Map<String, Folder> packageMap = <String, Folder>{};
    List<Resource> children = packagesFolder.getChildren();
    for (Resource child in children) {
      if (child is Folder) {
        packageMap[child.shortName] = child;
      }
    }
    // done
    return new PackageMapUriResolver(_resourceProvider, packageMap);
  }
}


/**
 * An enumeration of the services provided by the server domain.
 */
class ServerService extends Enum2<ServerService> {
  static const ServerService STATUS = const ServerService('STATUS', 0);

  static const List<ServerService> VALUES = const [STATUS];

  const ServerService(String name, int ordinal) : super(name, ordinal);
}
