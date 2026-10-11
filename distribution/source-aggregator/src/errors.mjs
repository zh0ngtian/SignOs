export class SourceError extends Error {
  constructor(code, message, status = 422, retryable = false, details = null) {
    super(message);
    Object.assign(this, { code, status, retryable, details });
  }
}

const reasons = {
  RANGE_UNSUPPORTED: '下载服务器不支持 HTTP Range 部分读取',
  BAD_CONTENT_RANGE: '服务器返回的文件区段与请求不一致',
  TRUNCATED_RANGE: '文件区段下载不完整',
  OBJECT_CHANGED: '读取期间文件发生变化，请重试',
  ENCODED_RANGE: '服务器对文件区段使用了不兼容的传输编码',
  EOCD_NOT_FOUND: '文件不是有效的 IPA，或 ZIP 结束目录已损坏',
  MULTIDISK_UNSUPPORTED: '不支持分卷 ZIP 文件',
  BAD_ZIP64: 'ZIP64 目录或偏移无效',
  DIRECTORY_LIMIT: 'ZIP 中央目录超过处理限额',
  BAD_DIRECTORY: 'ZIP 中央目录已损坏',
  MULTIPLE_MAIN_APPS: 'IPA 中包含多个主应用，无法确定目标应用',
  MAIN_PLIST_NOT_FOUND: 'IPA 中找不到主应用的 Info.plist',
  ENCRYPTED_UNSUPPORTED: 'IPA 内待解析的文件使用了不支持的加密方式',
  COMPRESSION_UNSUPPORTED: 'IPA 内待解析的文件使用了不支持的 ZIP 压缩方式',
  PLIST_LIMIT: 'Info.plist 超过处理大小限制',
  BAD_LOCAL_HEADER: 'ZIP 文件头与中央目录不一致',
  PLIST_SIZE_MISMATCH: 'Info.plist 解压后的长度不一致',
  ENTRY_SIZE_MISMATCH: 'IPA 文件解压后的长度与目录记录不一致',
  ICON_LIMIT: '应用图标或资源目录超过处理大小限制',
  ICON_EXTRACTION_FAILED: '无法从 IPA 提取主应用图标，已保留原版本，请检查图标格式',
  DECOMPRESSION_FAILED: 'IPA 内文件解压失败，文件可能已损坏',
  CRC_MISMATCH: 'IPA 内文件的 CRC-32 校验失败，文件可能已损坏',
  BAD_BINARY_PLIST: '二进制 Info.plist 格式无效',
  BAD_XML_PLIST: 'XML Info.plist 格式无效',
  UNSUPPORTED_XML_ENTITY: 'Info.plist 包含不支持的 XML 实体',
  UNSUPPORTED_PLIST_OBJECT: 'Info.plist 元信息使用了不支持的数据类型',
  INVALID_METADATA: 'Info.plist 缺少必要信息或字段格式无效',
  BODY_TOO_LARGE: '响应内容超过处理限额',
  BAD_REDIRECT: '下载重定向无效或次数过多',
  UNSAFE_OFFSET: 'ZIP 文件偏移无效',
};

export function errorData(error) {
  if (error instanceof SourceError) {
    return { code: error.code, message: error.message, retryable: error.retryable, details: error.details };
  }
  if (error.name === 'TimeoutError' || error.name === 'AbortError') {
    return { code: 'DOWNLOAD_TIMEOUT', message: '下载超时，请重试', retryable: true, details: null };
  }
  if (error.code && reasons[error.code]) {
    return { code: error.code, message: reasons[error.code], retryable: ['OBJECT_CHANGED', 'TRUNCATED_RANGE'].includes(error.code), details: error.message === error.code ? null : error.message };
  }
  return { code: 'UPSTREAM_ERROR', message: '上游访问或文件解压失败', retryable: false, details: null };
}

export function json(data, status = 200, headers = {}) {
  return Response.json(data, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers } });
}
