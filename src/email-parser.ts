import { simpleParser } from "mailparser";
import { Email, EmailAttachment } from "./types";
import { parseAddressHeader } from "./utils/addressing";

// Map to store embedded image Content-IDs for later reference
let contentIdMap: Map<string, EmailAttachment> = new Map();

export async function parseEmail(raw: string): Promise<Email> {
  // Reset the content ID map for each email
  contentIdMap = new Map();
  
  const parsed = await simpleParser(raw);
  
  // Process attachments and collect Content-IDs
  const attachments = parsed.attachments.map(attachment => {
    const emailAttachment: EmailAttachment = {
      filename: attachment.filename || 'unnamed-attachment',
      contentType: attachment.contentType,
      content: attachment.content,
      contentId: attachment.contentId
    };
    
    // Store attachments with Content-ID for inline image references
    if (attachment.contentId) {
      const cid = attachment.contentId.replace(/[<>]/g, '');
      contentIdMap.set(cid, emailAttachment);
    }
    
    return emailAttachment;
  });

  // Process HTML content to replace cid: references
  let html = parsed.html || '';
  if (html) {
    // Replace cid: references with data URLs
    html = html.replace(/src=["']cid:([^"']+)["']/g, (match, cid) => {
      const attachment = contentIdMap.get(cid);
      if (attachment) {
        const base64Content = attachment.content.toString('base64');
        return `src="data:${attachment.contentType};base64,${base64Content}"`;
      }
      return match;
    });
  }

  return {
    id: Math.random().toString(36).substring(2, 15),
    from: parseAddressHeader(parsed.from?.text || ''),
    to: parseAddressHeader(parsed.to?.text || ''),
    cc: parseAddressHeader(parsed.cc?.text || ''),
    bcc: parseAddressHeader(parsed.bcc?.text || ''),
    subject: parsed.subject || '',
    text: parsed.text || '',
    html: html,
    date: parsed.date || new Date(),
    attachments,
    raw,
    headers: parsed.headers
  };
}