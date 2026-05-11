import base64
import quopri
import re
from email.message import Message
from typing import List, Optional, Tuple, Dict

from bs4 import BeautifulSoup

from fmail.model import EmailPart


def extract_content_from_mime_part(part: Message) -> EmailPart:
    """Extract content from a MIME part."""
    content_type = part.get_content_type()
    content_disposition = part.get("Content-Disposition", "")
    charset = part.get_content_charset() or "utf-8"
    content_id = part.get("Content-ID", "")
    
    # Extract content ID from <cid:...> format
    if content_id and content_id.startswith("<") and content_id.endswith(">"):
        content_id = content_id[1:-1]  # Remove < and >

    # Get the payload
    if part.get("Content-Transfer-Encoding") == "base64":
        payload = part.get_payload(decode=True)
    else:
        payload = part.get_payload(decode=True)

    # Handle text content
    if content_type.startswith("text/"):
        try:
            text_content = payload.decode(charset, errors="replace")
            return EmailPart(
                content_type=content_type,
                content_disposition=content_disposition,
                content=text_content,
                content_id=content_id,
                raw_content=payload
            )
        except Exception as e:
            print(f"Error decoding text content: {e}")
            return EmailPart(
                content_type=content_type,
                content_disposition=content_disposition,
                content="[Content could not be decoded]",
                content_id=content_id,
                raw_content=payload
            )
    # Handle binary content
    else:
        return EmailPart(
            content_type=content_type,
            content_disposition=content_disposition,
            content=None,
            content_id=content_id,
            raw_content=payload
        )


def get_email_content_parts(email_message: Message) -> List[EmailPart]:
    """Extract all content parts from an email message."""
    parts = []
    
    # Handle multipart messages
    if email_message.is_multipart():
        for part in email_message.walk():
            if part.get_content_maintype() == "multipart":
                continue  # Skip multipart containers
            parts.append(extract_content_from_mime_part(part))
    # Handle single part messages
    else:
        parts.append(extract_content_from_mime_part(email_message))
        
    return parts


def get_email_content(email_message: Message) -> Tuple[str, str, List[EmailPart]]:
    """Get the text and HTML content from an email."""
    parts = get_email_content_parts(email_message)
    
    # Find the text and HTML parts
    text_content = ""
    html_content = ""
    attachments = []

    # Process all parts
    content_id_map = {}
    
    for part in parts:
        content_disp = part.content_disposition.lower() if part.content_disposition else ""
        
        # Map Content-IDs to their parts for embedded images
        if part.content_id and part.raw_content:
            content_id_map[part.content_id] = part
            
        # Text content
        if "attachment" not in content_disp:
            if part.content_type == "text/plain" and part.content:
                text_content = part.content
            elif part.content_type == "text/html" and part.content:
                html_content = part.content
        
        # Attachments
        if "attachment" in content_disp or not (part.content_type == "text/plain" or part.content_type == "text/html"):
            attachments.append(part)
    
    # Process embedded images in HTML
    if html_content and content_id_map:
        html_content = process_embedded_images(html_content, content_id_map)
    
    return text_content, html_content, attachments


def process_embedded_images(html_content: str, content_id_map: Dict[str, EmailPart]) -> str:
    """Process embedded images in HTML content."""
    soup = BeautifulSoup(html_content, "html.parser")
    
    # Find all image tags
    for img in soup.find_all("img"):
        src = img.get("src", "")
        
        # Check for CID references
        cid_match = re.match(r'cid:([^"\'> ]+)', src)
        if cid_match:
            cid = cid_match.group(1)
            
            # If we have this content ID in our map
            if cid in content_id_map:
                part = content_id_map[cid]
                if part.raw_content:
                    # Create a data URI for the image
                    img_type = part.content_type
                    img_data = base64.b64encode(part.raw_content).decode('ascii')
                    data_uri = f"data:{img_type};base64,{img_data}"
                    
                    # Replace the CID reference with the data URI
                    img['src'] = data_uri
    
    return str(soup)