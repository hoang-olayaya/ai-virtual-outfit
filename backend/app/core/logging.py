import logging
import re
import sys
from typing import Any
from app.core.config import settings


class SecretMaskingFilter(logging.Filter):
    """
    Log filter that masks sensitive API keys and authorization tokens from log output.
    """

    _KEY_PATTERN = re.compile(r"(Key\s+)([a-zA-Z0-9_\-]{16,})")
    _AUTH_BEARER_PATTERN = re.compile(r"(Bearer\s+)([a-zA-Z0-9_\-\.]{16,})", re.IGNORECASE)

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.msg, str):
            record.msg = self.mask_text(record.msg)
        if record.args:
            if isinstance(record.args, dict):
                record.args = {k: self.mask_value(v) for k, v in record.args.items()}
            elif isinstance(record.args, tuple):
                record.args = tuple(self.mask_value(v) for v in record.args)
        return True

    @classmethod
    def mask_text(cls, text: str) -> str:
        if not text:
            return text
        fal_key = (settings.FAL_KEY or "").strip()
        if fal_key and fal_key in text:
            text = text.replace(fal_key, "******")
        text = cls._KEY_PATTERN.sub(r"\1******", text)
        text = cls._AUTH_BEARER_PATTERN.sub(r"\1******", text)
        return text

    @classmethod
    def mask_value(cls, val: Any) -> Any:
        if isinstance(val, str):
            return cls.mask_text(val)
        return val


def setup_logging() -> None:
    log_level = logging.DEBUG if settings.DEBUG else logging.INFO
    log_format = "%(asctime)s [%(levelname)s] [%(name)s]: %(message)s"

    handler = logging.StreamHandler(sys.stdout)
    handler.addFilter(SecretMaskingFilter())

    logging.basicConfig(
        level=log_level,
        format=log_format,
        handlers=[handler],
        force=True,
    )

    # Attach secret filter to root logger and application logger
    root_logger = logging.getLogger()
    if not any(isinstance(f, SecretMaskingFilter) for f in root_logger.filters):
        root_logger.addFilter(SecretMaskingFilter())

    # Silence overly verbose external loggers
    logging.getLogger("uvicorn.access").setLevel(logging.INFO)
    logging.getLogger("asyncio").setLevel(logging.WARNING)


logger = logging.getLogger("ai_virtual_outfit")
if not any(isinstance(f, SecretMaskingFilter) for f in logger.filters):
    logger.addFilter(SecretMaskingFilter())
