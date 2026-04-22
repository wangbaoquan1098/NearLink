import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../services/file_transfer_service.dart';
import '../utils/file_utils.dart';
import '../utils/extensions.dart';
import '../widgets/nearlink_widgets.dart';

class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({super.key});

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  final FileTransferService _fileTransferService = FileTransferService();
  late Future<List<FileSystemEntity>> _filesFuture;
  String? _directoryPath;

  @override
  void initState() {
    super.initState();
    _reloadFiles();
  }

  void _reloadFiles() {
    setState(() {
      _filesFuture = _loadFiles();
    });
  }

  Future<List<FileSystemEntity>> _loadFiles() async {
    _directoryPath = await _fileTransferService.getNearLinkDirectoryPath(
      ensureExists: true,
      requestPermissionIfNeeded: Platform.isAndroid,
    );
    return _fileTransferService.listSavedFiles();
  }

  Future<void> _openFile(File file) async {
    final result = await OpenFilex.open(file.path);
    if (!mounted) return;
    if (result.type == ResultType.done) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message.isNotEmpty ? result.message : '无法打开文件'),
        backgroundColor: NearLinkColors.error,
      ),
    );
  }

  Future<void> _shareFile(File file) async {
    await Share.shareXFiles(
      [XFile(file.path)],
      text: file.path.split(Platform.pathSeparator).last,
    );
  }

  Future<void> _deleteFile(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文件'),
        content:
            Text('确定要删除“${file.path.split(Platform.pathSeparator).last}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    final success = await _fileTransferService.deleteSavedFile(file.path);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(success ? '文件已删除' : '删除失败'),
        backgroundColor:
            success ? NearLinkColors.success : NearLinkColors.error,
      ),
    );

    if (success) {
      _reloadFiles();
    }
  }

  Future<void> _showFileActions(File file) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开文件'),
              onTap: () {
                Navigator.of(context).pop();
                _openFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('分享文件'),
              onTap: () {
                Navigator.of(context).pop();
                _shareFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除文件'),
              textColor: NearLinkColors.error,
              iconColor: NearLinkColors.error,
              onTap: () {
                Navigator.of(context).pop();
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NearLink 文件'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reloadFiles,
          ),
        ],
      ),
      body: FutureBuilder<List<FileSystemEntity>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return _buildEmptyState(
              icon: Icons.error_outline,
              title: '读取文件失败',
              subtitle: '${snapshot.error}',
            );
          }

          final files = snapshot.data ?? const <FileSystemEntity>[];
          if (files.isEmpty) {
            return _buildEmptyState(
              icon: Icons.folder_open,
              title: 'NearLink 文件夹还是空的',
              subtitle: _directoryPath ?? '还没有接收到任何文件',
            );
          }

          return Column(
            children: [
              if (_directoryPath != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    _directoryPath!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NearLinkColors.textSecondary,
                    ),
                  ),
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: files.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final file = files[index] as File;
                    final stat = file.statSync();
                    final fileName =
                        file.path.split(Platform.pathSeparator).last;

                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: NearLinkColors.primary.o(0.12),
                          child: Icon(
                            FileUtils.getFileIconByName(fileName),
                            color: NearLinkColors.primary,
                          ),
                        ),
                        title: Text(
                          fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${FileUtils.formatFileSize(stat.size)}  ·  ${_formatModifiedTime(stat.modified)}',
                        ),
                        onTap: () => _openFile(file),
                        trailing: IconButton(
                          icon: const Icon(Icons.more_horiz),
                          onPressed: () => _showFileActions(file),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: NearLinkColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NearLinkColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  String _formatModifiedTime(DateTime modifiedAt) {
    final now = DateTime.now();
    final difference = now.difference(modifiedAt);

    if (difference.inMinutes < 1) {
      return '刚刚';
    }
    if (difference.inHours < 1) {
      return '${difference.inMinutes} 分钟前';
    }
    if (difference.inDays < 1) {
      return '${difference.inHours} 小时前';
    }
    return '${modifiedAt.year}-${modifiedAt.month.toString().padLeft(2, '0')}-${modifiedAt.day.toString().padLeft(2, '0')}';
  }
}
