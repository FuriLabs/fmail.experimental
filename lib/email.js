// Import necessary modules
const cheerio = require('cheerio');

// Render an email for display in the UI
function renderEmail(email) {
  // Prepare a map of Content-IDs to attachment data for embedded images
  const cidMap = {};
  if (email.attachments) {
    email.attachments.forEach(attachment => {
      if (attachment.contentId) {
        // Remove angle brackets if present
        const cid = attachment.contentId.replace(/[<>]/g, '');
        cidMap[`cid:${cid}`] = `data:${attachment.contentType};base64,${attachment.content}`;
      }
    });
  }

  // Replace CID references in HTML content
  if (email.html && Object.keys(cidMap).length > 0) {
    const $ = cheerio.load(email.html);
    $('img').each(function() {
      const src = $(this).attr('src');
      if (src && cidMap[src]) {
        $(this).attr('src', cidMap[src]);
      }
    });
    email.html = $.html();
  }

  return email;
}

module.exports = {
  renderEmail,
};