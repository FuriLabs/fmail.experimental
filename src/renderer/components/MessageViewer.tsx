import React, { useEffect, useState, useRef } from 'react';
import { IconButton, Typography, Box, Button } from '@mui/material';
import ArrowBackIcon from '@mui/icons-material/ArrowBack';
import { IMessage } from '../../types';
import { extractAddresses } from '../utils/emailUtils';
import { formatDate } from '../utils/dateUtils';
import { useNavigate } from 'react-router-dom';
import { useDispatch, useSelector } from 'react-redux';
import { RootState } from '../store';
import { setReplyTo, setForward } from '../slices/composeSlice';
import UnsubscribeIcon from '@mui/icons-material/Unsubscribe';

const MessageViewer: React.FC<{ message: IMessage }> = ({ message }) => {
  const navigate = useNavigate();
  const dispatch = useDispatch();
  const [htmlContent, setHtmlContent] = useState<string>('');
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const accounts = useSelector((state: RootState) => state.accounts.accounts);
  const activeAccountId = useSelector((state: RootState) => state.accounts.activeAccountId);

  useEffect(() => {
    if (message && message.htmlContent) {
      // Process embedded images in the HTML content
      window.electron.ipcRenderer.invoke('process-embedded-images', {
        messageId: message.id,
        htmlContent: message.htmlContent
      }).then((processedContent: string) => {
        setHtmlContent(processedContent);
      });
    } else {
      setHtmlContent(message?.textContent || '');
    }
  }, [message]);

  useEffect(() => {
    if (iframeRef.current && iframeRef.current.contentWindow) {
      const iframeDocument = iframeRef.current.contentWindow.document;
      iframeDocument.open();
      iframeDocument.write(htmlContent);
      iframeDocument.close();

      // Add event listener to handle clicks on links
      iframeDocument.addEventListener('click', (e) => {
        const target = e.target as HTMLAnchorElement;
        if (target.tagName === 'A' && target.href) {
          e.preventDefault();
          window.electron.ipcRenderer.send('open-external-url', target.href);
        }
      });
    }
  }, [htmlContent]);

  const handleBack = () => {
    navigate(-1);
  };

  const handleReply = () => {
    // Find the active account to get the signature
    const activeAccount = accounts.find(acc => acc.id === activeAccountId);
    const signature = activeAccount?.signature || '';
    
    dispatch(setReplyTo({ 
      message, 
      includeSignature: true,
      signature
    }));
    navigate('/compose');
  };

  const handleForward = () => {
    // Find the active account to get the signature
    const activeAccount = accounts.find(acc => acc.id === activeAccountId);
    const signature = activeAccount?.signature || '';
    
    dispatch(setForward({ 
      message,
      includeSignature: true,
      signature
    }));
    navigate('/compose');
  };

  const handleUnsubscribe = () => {
    if (!message) return;
    
    // First check List-Unsubscribe header
    if (message.headers && message.headers['List-Unsubscribe']) {
      const unsubscribeHeader = message.headers['List-Unsubscribe'];
      // Extract URL from <http://...> format
      const match = unsubscribeHeader.match(/<(https?:[^>]+)>/i);
      if (match && match[1]) {
        window.electron.ipcRenderer.send('open-external-url', match[1]);
        return;
      }
    }
    
    // If no header, try to find unsubscribe link in the content
    window.electron.ipcRenderer.invoke('find-unsubscribe-link', message.id)
      .then((unsubscribeUrl: string | null) => {
        if (unsubscribeUrl) {
          window.electron.ipcRenderer.send('open-external-url', unsubscribeUrl);
        } else {
          alert('No unsubscribe link found in this email');
        }
      });
  };

  if (!message) return <Typography>Loading...</Typography>;

  return (
    <Box sx={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <Box sx={{ p: 2, borderBottom: '1px solid #e0e0e0', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <IconButton onClick={handleBack} size="large">
          <ArrowBackIcon />
        </IconButton>
        <Box sx={{ display: 'flex', gap: 1 }}>
          <Button variant="outlined" onClick={handleReply}>Reply</Button>
          <Button variant="outlined" onClick={handleForward}>Forward</Button>
          <IconButton onClick={handleUnsubscribe} title="Unsubscribe" color="primary">
            <UnsubscribeIcon />
          </IconButton>
        </Box>
      </Box>
      
      <Box sx={{ p: 2, borderBottom: '1px solid #e0e0e0' }}>
        <Typography variant="h6">{message.subject}</Typography>
        <Box sx={{ display: 'flex', justifyContent: 'space-between', mt: 1 }}>
          <Box>
            <Typography variant="body2">From: {message.from}</Typography>
            <Typography variant="body2">To: {extractAddresses(message.to).join(', ')}</Typography>
            {message.cc && <Typography variant="body2">Cc: {extractAddresses(message.cc).join(', ')}</Typography>}
          </Box>
          <Typography variant="body2">{formatDate(message.date)}</Typography>
        </Box>
      </Box>
      
      <Box sx={{ flexGrow: 1, overflow: 'auto', p: 2 }}>
        <iframe 
          ref={iframeRef}
          style={{ width: '100%', height: '100%', border: 'none' }}
          title="Email Content"
          sandbox="allow-same-origin allow-popups"
        />
      </Box>
    </Box>
  );
};

export default MessageViewer;