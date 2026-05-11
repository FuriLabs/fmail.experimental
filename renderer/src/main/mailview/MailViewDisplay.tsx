import React, { useState, useEffect } from 'react';
import parse, { DOMNode, Element, domToReact } from 'html-react-parser';
import './MailViewDisplay.css';
import { MailAttachment } from '../../../shared/types';

type Props = {
  mail: {
    html?: string;
    text?: string;
  };
  attachments?: MailAttachment[];
};

function MailViewDisplay({ mail, attachments = [] }: Props) {
  const [html, setHtml] = useState<string>('');

  useEffect(() => {
    if (!mail) return;

    const content = mail.html || mail.text || '';
    
    // Create a map of Content-ID to attachment for fast lookup
    const cidMap = new Map<string, MailAttachment>();
    
    // Process attachments to find inline images with Content-IDs
    attachments.forEach(attachment => {
      if (attachment.contentId) {
        // Remove angle brackets if they exist in the Content-ID
        const cleanCid = attachment.contentId.replace(/[<>]/g, '');
        cidMap.set(cleanCid, attachment);
      }
    });

    // Process the HTML content to replace Content-ID references with data URLs
    if (mail.html) {
      setHtml(mail.html);
    } else {
      setHtml(`<pre>${content}</pre>`);
    }
  }, [mail, attachments]);

  // Custom options for html-react-parser
  const options = {
    replace: (domNode: DOMNode) => {
      if (domNode instanceof Element && domNode.name === 'img') {
        // Check if the src attribute contains a Content-ID reference
        const src = domNode.attribs.src;
        
        if (src && src.startsWith('cid:')) {
          // Extract the Content-ID
          const cid = src.substring(4);
          
          // Find the matching attachment
          const attachment = attachments.find(
            att => att.contentId === `<${cid}>` || att.contentId === cid
          );
          
          if (attachment && attachment.dataUrl) {
            // Replace the src with the data URL
            return (
              <img
                {...domNode.attribs}
                src={attachment.dataUrl}
                alt={attachment.filename || 'Embedded image'}
              />
            );
          }
        }
      }
      return undefined;
    }
  };

  return (
    <div className="mail-view-display">
      {html ? parse(html, options) : null}
    </div>
  );
}

export default MailViewDisplay;