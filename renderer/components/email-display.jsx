import React, { useState, useEffect } from 'react';
import DOMPurify from 'dompurify';

export default function EmailDisplay({ email }) {
  const [htmlContent, setHtmlContent] = useState('');

  useEffect(() => {
    if (email) {
      // Process and sanitize HTML content
      let content = email.isHtml ? email.body : `<pre>${email.body}</pre>`;
      
      // Handle embedded images (cid: protocol)
      if (email.isHtml && email.attachments) {
        email.attachments.forEach(attachment => {
          if (attachment.contentId) {
            const cidPattern = new RegExp(`cid:${attachment.contentId.replace(/[<>]/g, '')}`, 'g');
            content = content.replace(cidPattern, `data:${attachment.contentType};base64,${attachment.content}`);
          }
        });
      }
      
      const sanitized = DOMPurify.sanitize(content, {
        ADD_TAGS: ['style'],
        ADD_ATTR: ['target'],
        FORBID_TAGS: ['script', 'iframe'],
        FORBID_ATTR: ['onerror', 'onload', 'onclick']
      });
      setHtmlContent(sanitized);
    }
  }, [email]);

  if (!email) return <div className="email-display empty">Select an email to view</div>;

  return (
    <div className="email-display">
      <div className="email-header">
        <div className="header-row">
          <span className="label">From:</span>
          <span className="value">{email.from}</span>
          
          {email.unsubscribeUrl && (
            <button 
              className="unsubscribe-button" 
              onClick={() => window.electron.openExternal(email.unsubscribeUrl)}
            >
              UNSUBSCRIBE
            </button>
          )}
        </div>
        <div className="header-row">
          <span className="label">To:</span>
          <span className="value">{email.to}</span>
        </div>
        {email.cc && (
          <div className="header-row">
            <span className="label">CC:</span>
            <span className="value">{email.cc}</span>
          </div>
        )}
        <div className="header-row">
          <span className="label">Subject:</span>
          <span className="value">{email.subject}</span>
        </div>
        <div className="header-row">
          <span className="label">Date:</span>
          <span className="value">{new Date(email.date).toLocaleString()}</span>
        </div>
      </div>
      <div 
        className="email-body" 
        dangerouslySetInnerHTML={{ __html: htmlContent }}
      />
    </div>
  );
}