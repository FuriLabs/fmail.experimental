import React from 'react';

interface EmailAttachment {
  contentId?: string;
  contentType: string;
  data: string;
}

interface Email {
  subject: string;
  from: string;
  to: string;
  cc?: string;
  date: string;
  content: string;
  contentType?: string;
  attachments?: EmailAttachment[];
}

interface EmailDisplayProps {
  email: Email;
}

const processContentWithEmbeddedImages = (content: string, attachments: EmailAttachment[]): string => {
  if (!content || !attachments || attachments.length === 0) return content;
  
  // Create a mapping of Content-IDs to attachment data
  const cidMap = new Map<string, EmailAttachment>();
  attachments.forEach(attachment => {
    if (attachment.contentId) {
      // Remove angle brackets if they exist
      const cleanCid = attachment.contentId.replace(/^<|>$/g, '');
      cidMap.set(cleanCid, attachment);
    }
  });

  // Replace cid: references with data URLs
  return content.replace(/src="cid:([^"]+)"/g, (match, cid) => {
    const attachment = cidMap.get(cid);
    if (!attachment || !attachment.data) {
      return match; // Keep original if no matching attachment
    }
    
    // Create data URL from attachment
    const dataUrl = `data:${attachment.contentType};base64,${attachment.data}`;
    return `src="${dataUrl}"`;
  });
};

const EmailDisplay: React.FC<EmailDisplayProps> = ({ email }) => {
  const processedContent = email.contentType?.includes('text/html') 
    ? processContentWithEmbeddedImages(email.content, email.attachments || []) 
    : email.content;

  return (
    <div className="email-display">
      <div className="email-header">
        <div className="email-metadata">
          <div className="email-subject">{email.subject}</div>
          <div className="email-from">From: {email.from}</div>
          <div className="email-to">To: {email.to}</div>
          {email.cc && <div className="email-cc">Cc: {email.cc}</div>}
          <div className="email-date">{new Date(email.date).toLocaleString()}</div>
        </div>
      </div>
      
      <div className="email-content">
        {email.contentType?.includes('text/html') ? (
          <div dangerouslySetInnerHTML={{ __html: processedContent }} />
        ) : (
          <pre>{processedContent}</pre>
        )}
      </div>
    </div>
  );
};

export default EmailDisplay;