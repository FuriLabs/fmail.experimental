import React, { useContext, useEffect, useState, useRef } from "react";
import { Message } from "../../electron/db/models";
import { ipcRenderer } from "electron";
import { AccountContext, MailboxContext } from "./Contexts";
import { Button, Divider, Empty, List, Space, Tag, Tooltip, Typography } from "antd";
import { 
  DeleteOutlined, 
  MailOutlined, 
  StarOutlined, 
  StarFilled, 
  UnorderedListOutlined, 
  StopOutlined
} from "@ant-design/icons";
import { getMailboxes } from "../../electron/db/getters";
import { serialMutexMap } from "../../electron/utils/mutex";
import SelectMailbox from "./SelectMailbox";
import moment from 'moment';
import DOMPurify from 'dompurify';

function MessageViewer() {
  const { account } = useContext(AccountContext);
  const { mailbox, mailboxes, setMailboxes } = useContext(MailboxContext);
  const [message, setMessage] = useState<Message | null>(null);
  const [messageContent, setMessageContent] = useState<string | null>(null);
  const [viewType, setViewType] = useState<"text" | "html" | "headers">("text");
  const [showReply, setShowReply] = useState(false);
  const contentRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleMessageBodyRender = () => {
      if (viewType === "html" && messageContent && contentRef.current) {
        // Sanitize HTML content
        const sanitizedHtml = DOMPurify.sanitize(messageContent);
        contentRef.current.innerHTML = sanitizedHtml;
        
        // Process embedded images (CID references)
        if (message && message.id) {
          // Query all images with cid: references
          const imgElements = contentRef.current.querySelectorAll('img[src^="cid:"]');
          imgElements.forEach(async (img) => {
            const cidSrc = img.getAttribute('src');
            if (cidSrc && cidSrc.startsWith('cid:')) {
              const contentId = cidSrc.substring(4); // Remove 'cid:' prefix
              try {
                // Request the inline attachment data from main process
                const imageData = await ipcRenderer.invoke('get-inline-attachment', message.id, contentId);
                if (imageData) {
                  // Set the image source to the base64 data
                  img.setAttribute('src', `data:${imageData.contentType};base64,${imageData.data}`);
                }
              } catch (error) {
                console.error('Failed to load embedded image:', error);
              }
            }
          });
        }
        
        // Make all links open in external browser
        const links = contentRef.current.querySelectorAll('a');
        links.forEach(link => {
          link.setAttribute('target', '_blank');
          link.setAttribute('rel', 'noopener noreferrer');
        });
      }
    };

    handleMessageBodyRender();
  }, [messageContent, viewType, message]);

  const handleDelete = () => {
    if (message && mailbox) {
      ipcRenderer.invoke("delete-message", message.id, mailbox.id).then(() => {
        setMessage(null);
      });
    }
  };

  const handleStar = () => {
    if (message) {
      ipcRenderer.invoke("toggle-star", message.id).then((starred) => {
        setMessage((prev) => (prev ? { ...prev, starred } : prev));
      });
    }
  };

  const handleMove = (targetMailboxId: string) => {
    if (message && mailbox) {
      ipcRenderer.invoke("move-message", message.id, mailbox.id, targetMailboxId).then(() => {
        setMessage(null);
      });
    }
  };

  const renderHeaders = () => {
    if (message && message.headers) {
      return Object.entries(message.headers)
        .map(([key, value]) => `${key}: ${value}`)
        .join("\n");
    }
    return "";
  };

  const handleUnsubscribe = () => {
    if (message && message.headers) {
      // Check for List-Unsubscribe header
      const unsubscribeHeader = message.headers['list-unsubscribe'];
      if (unsubscribeHeader) {
        // Extract URL from the header (typically between < and >)
        const match = unsubscribeHeader.match(/<([^>]+)>/);
        if (match && match[1]) {
          const unsubscribeUrl = match[1];
          // Open the URL in default browser
          ipcRenderer.send('open-external-link', unsubscribeUrl);
          return;
        }
      }
      
      // Look for unsubscribe links in email body as fallback
      if (contentRef.current) {
        const links = contentRef.current.querySelectorAll('a');
        for (const link of links) {
          const href = link.getAttribute('href');
          const text = link.textContent?.toLowerCase() || '';
          if (href && (text.includes('unsubscribe') || text.includes('opt out') || 
                       href.toLowerCase().includes('unsubscribe'))) {
            ipcRenderer.send('open-external-link', href);
            return;
          }
        }
      }
      
      console.log("No unsubscribe link found");
    }
  };

  return (
    <div style={{ height: "100%" }}>
      {message ? (
        <div style={{ height: "100%", display: "flex", flexDirection: "column" }}>
          <div style={{ padding: "12px", borderBottom: "1px solid #e8e8e8" }}>
            <div style={{ marginBottom: "8px" }}>
              <Space>
                <Button
                  icon={<DeleteOutlined />}
                  onClick={handleDelete}
                ></Button>
                <Button
                  icon={
                    message.starred ? <StarFilled /> : <StarOutlined />
                  }
                  onClick={handleStar}
                ></Button>
                <Button
                  icon={<MailOutlined />}
                  onClick={() => setShowReply(true)}
                >
                  Reply
                </Button>
                <SelectMailbox
                  trigger="click"
                  mailboxes={mailboxes.filter((m) => m.id !== mailbox.id)}
                  onSelect={handleMove}
                >
                  <Button icon={<UnorderedListOutlined />}>Move</Button>
                </SelectMailbox>
                
                {message.headers && (message.headers['list-unsubscribe'] || contentRef.current?.querySelectorAll('a[href*="unsubscribe"]').length > 0) && (
                  <Button 
                    icon={<StopOutlined />} 
                    onClick={handleUnsubscribe}
                    danger
                  >
                    Unsubscribe
                  </Button>
                )}
              </Space>
            </div>
            <Typography.Title level={4}>{message.subject}</Typography.Title>
            <Typography.Text type="secondary">
              {moment(message.date).format("LLLL")}
            </Typography.Text>
          </div>
          <div
            style={{
              flexGrow: 1,
              overflowY: "auto",
              padding: "12px",
              backgroundColor: "#fff",
            }}
          >
            <div style={{ marginBottom: "16px" }}>
              <Button.Group>
                <Button
                  type={viewType === "text" ? "primary" : "default"}
                  onClick={() => setViewType("text")}
                >
                  Text
                </Button>
                <Button
                  type={viewType === "html" ? "primary" : "default"}
                  onClick={() => setViewType("html")}
                  disabled={!message.html}
                >
                  HTML
                </Button>
                <Button
                  type={viewType === "headers" ? "primary" : "default"}
                  onClick={() => setViewType("headers")}
                >
                  Headers
                </Button>
              </Button.Group>
            </div>
            {viewType === "text" && (
              <Typography.Paragraph style={{ whiteSpace: "pre-wrap" }}>
                {messageContent}
              </Typography.Paragraph>
            )}
            {viewType === "html" && <div ref={contentRef} />}
            {viewType === "headers" && (
              <Typography.Paragraph style={{ whiteSpace: "pre-wrap" }}>
                {renderHeaders()}
              </Typography.Paragraph>
            )}
          </div>
        </div>
      ) : (
        <Empty description="Select a message to view" />
      )}
    </div>
  );
}

export default MessageViewer;