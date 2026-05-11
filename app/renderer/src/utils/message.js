export function processEmailContent(message) {
  let htmlContent = message.html;

  // Handle embedded images (CID references)
  if (htmlContent && message.attachments && message.attachments.length > 0) {
    // Create a map of Content-ID to attachment for quick lookup
    const cidMap = {};
    message.attachments.forEach(attachment => {
      if (attachment.contentId) {
        // Remove angle brackets from Content-ID if present
        const cleanCid = attachment.contentId.replace(/[<>]/g, '');
        cidMap[cleanCid] = attachment;
      }
    });
    
    // Replace cid: URLs with data URLs
    htmlContent = htmlContent.replace(/src="cid:([^"]+)"/g, (match, cid) => {
      const attachment = cidMap[cid];
      if (attachment && attachment.content) {
        // Convert the attachment content to a data URL
        const base64Content = attachment.content.toString('base64');
        const mimeType = attachment.contentType || 'image/jpeg';
        return `src="data:${mimeType};base64,${base64Content}"`;
      }
      return match; // Keep original if no matching attachment found
    });
  }

  return htmlContent;
}