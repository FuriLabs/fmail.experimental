import React, { useEffect, useState } from 'react';
import DOMPurify from 'dompurify';
import './EmailRenderer.css';

interface EmailRendererProps {
  email: any;
  showImages: boolean;
}

const EmailRenderer: React.FC<EmailRendererProps> = ({ email, showImages }) => {
  const [content, setContent] = useState<string>('');

  useEffect(() => {
    if (!email) return;

    const processContent = () => {
      let processedContent = '';

      if (email.html) {
        // Handle embedded images in HTML content
        const parser = new DOMParser();
        const doc = parser.parseFromString(email.html, 'text/html');
        
        // Process <img> tags that might reference Content-ID (CID) images
        if (email.attachments && email.attachments.length > 0) {
          const imgElements = doc.querySelectorAll('img');
          
          imgElements.forEach((img) => {
            const src = img.getAttribute('src');
            if (src && src.startsWith('cid:')) {
              const contentId = src.substring(4); // Remove 'cid:' prefix
              const matchingAttachment = email.attachments.find(
                (att: any) => att.contentId === contentId || `<${att.contentId}>` === contentId
              );
              
              if (matchingAttachment && matchingAttachment.content) {
                // Replace CID reference with base64-encoded data
                img.setAttribute(
                  'src',
                  `data:${matchingAttachment.contentType};base64,${matchingAttachment.content}`
                );
              }
            }
          });
        }
        
        processedContent = doc.documentElement.outerHTML;
      } else if (email.text) {
        processedContent = email.text.replace(/\n/g, '<br>');
      }

      // Sanitize content
      return DOMPurify.sanitize(processedContent);
    };

    setContent(processContent());
  }, [email, showImages]);

  if (!email) return null;

  return (
    <div className="email-renderer">
      <div
        className="email-content"
        dangerouslySetInnerHTML={{ __html: content }}
      />
    </div>
  );
};

export default EmailRenderer;