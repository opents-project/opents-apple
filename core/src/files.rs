use std::{
    collections::{BTreeMap, HashMap},
    future::pending,
    io,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    fs::File,
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::{mpsc, oneshot, watch},
    task::JoinHandle,
    time::{timeout, Instant},
};
use ts_bookkeeping::messages::c2s::{
    OutFileListRequestPart, OutInitDownloadPart, OutInitUploadPart,
};
use tsclientlib::{prelude::*, ChannelId, Connection, InMessage, MessageHandle, StreamItem};

#[derive(Clone, uniffi::Record)]
pub struct RemoteChannelFile {
    pub name: String,
    pub size: u64,
    pub directory: bool,
}
#[derive(uniffi::Record)]
pub struct ChannelFileResult {
    pub entries: Vec<RemoteChannelFile>,
    pub error: Option<String>,
}
type Outcome = Result<Vec<RemoteChannelFile>, String>;
impl From<Outcome> for ChannelFileResult {
    fn from(result: Outcome) -> Self {
        match result {
            Ok(entries) => Self {
                entries,
                error: None,
            },
            Err(error) => Self {
                entries: Vec::new(),
                error: Some(error),
            },
        }
    }
}

#[derive(uniffi::Object)]
pub struct ChannelFileJob {
    channel: u64,
    password: String,
    generation: u64,
    sender: mpsc::Sender<Request>,
    cancel: watch::Sender<bool>,
    progress: Arc<Progress>,
}
pub(crate) fn job(
    channel: u64,
    password: String,
    generation: u64,
    sender: mpsc::Sender<Request>,
) -> Arc<ChannelFileJob> {
    Arc::new(ChannelFileJob {
        channel,
        password,
        generation,
        sender,
        cancel: watch::channel(false).0,
        progress: Default::default(),
    })
}
#[derive(Default)]
struct Progress {
    bytes: AtomicU64,
    total: AtomicU64,
}

enum Operation {
    List,
    Upload(std::fs::File, u64),
    Download(PathBuf),
}
pub(crate) struct Request {
    channel: u64,
    password: String,
    generation: u64,
    path: String,
    op: Operation,
    cancel: watch::Receiver<bool>,
    reply: oneshot::Sender<Outcome>,
    progress: Arc<Progress>,
}
fn safe_component(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains(['/', '\\'])
        && !name.chars().any(char::is_control)
}
impl ChannelFileJob {
    async fn request(&self, path: String, op: Operation) -> ChannelFileResult {
        if !(path == "/" && matches!(op, Operation::List)
            || path
                .strip_prefix('/')
                .is_some_and(|p| p.split('/').all(safe_component)))
        {
            return Err("Invalid remote path".into()).into();
        }
        let (reply, rx) = oneshot::channel();
        let request = Request {
            channel: self.channel,
            password: self.password.clone(),
            generation: self.generation,
            path,
            op,
            cancel: self.cancel.subscribe(),
            progress: self.progress.clone(),
            reply,
        };
        if self.sender.try_send(request).is_err() {
            return Err("File service unavailable".into()).into();
        }
        rx.await
            .unwrap_or_else(|_| Err("Connection interrupted".into()))
            .into()
    }
}
#[uniffi::export]
impl ChannelFileJob {
    pub fn transferred_fraction(&self) -> Option<f64> {
        let total = self.progress.total.load(Ordering::Relaxed);
        (total > 0).then(|| self.progress.bytes.load(Ordering::Relaxed) as f64 / total as f64)
    }
    pub fn cancel(&self) {
        self.cancel.send_replace(true);
    }
    pub async fn list_files(&self, path: String) -> ChannelFileResult {
        self.request(path, Operation::List).await
    }
    pub async fn download(&self, path: String, destination: String) -> ChannelFileResult {
        self.request(path, Operation::Download(destination.into()))
            .await
    }
    pub async fn upload(&self, path: String, source: String) -> ChannelFileResult {
        let input = std::fs::File::open(source).and_then(|f| {
            let meta = f.metadata()?;
            if !meta.is_file() {
                return Err(io::Error::other("Select a regular file"));
            }
            Ok((f, meta.len()))
        });
        match input {
            Ok((file, size)) => self.request(path, Operation::Upload(file, size)).await,
            Err(e) => Err(e.to_string()).into(),
        }
    }
}

struct Active {
    request: Request,
    command: MessageHandle,
    id: u16,
    rows: BTreeMap<String, RemoteChannelFile>,
    deadline: Instant,
    copy: Option<JoinHandle<io::Result<()>>>,
    upload_confirmed: watch::Sender<bool>,
}
impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(copy) = self.active.as_mut().and_then(|a| a.copy.take()) {
            copy.abort()
        }
    }
}
#[derive(Default)]
pub(crate) struct Worker {
    active: Option<Active>,
    next_id: u16,
    // The finish notification has only channel and path. Drain an abandoned list
    // before allowing another request for that same directory.
    abandoned: HashMap<(u64, String), MessageHandle>,
}
impl Worker {
    pub(crate) fn start(&mut self, r: Request, con: &mut Connection, ready: bool, generation: u64) {
        if self
            .active
            .as_ref()
            .is_some_and(|a| *a.request.cancel.borrow())
        {
            self.abandon_list();
            self.finish(Err("Cancelled".into()));
        }
        let result = (|| {
            if self.active.is_some() {
                return Err("Another file operation is in progress".into());
            }
            if !ready || generation != r.generation {
                return Err("Connection interrupted".into());
            }
            if *r.cancel.borrow() {
                return Err("Cancelled".into());
            }
            if matches!(r.op, Operation::List)
                && self.abandoned.contains_key(&(r.channel, r.path.clone()))
            {
                return Err(
                    "The previous directory request is still pending. Retry or reconnect.".into(),
                );
            }
            let channel_id = ChannelId(r.channel);
            let channel_password = if r.password.is_empty() {
                String::new()
            } else {
                tsproto_types::crypto::encode_password(r.password.as_bytes())
            }
            .into();
            let name = r.path.as_str().into();
            self.next_id = self.next_id.wrapping_add(1);
            let client_filetransfer_id = self.next_id;
            match &r.op {
                Operation::List => OutFileListRequestPart {
                    channel_id,
                    channel_password,
                    path: name,
                }
                .send_with_result(con),
                Operation::Upload(_, size) => OutInitUploadPart {
                    channel_id,
                    channel_password,
                    name,
                    client_filetransfer_id,
                    size: *size,
                    overwrite: false,
                    resume: false,
                    protocol: 1,
                }
                .send_with_result(con),
                Operation::Download(_) => OutInitDownloadPart {
                    channel_id,
                    channel_password,
                    name,
                    client_filetransfer_id,
                    seek_position: 0,
                    protocol: 1,
                }
                .send_with_result(con),
            }
            .map_err(|e| e.to_string())
        })();
        match result {
            Ok(command) => {
                self.active = Some(Active {
                    request: r,
                    command,
                    id: self.next_id,
                    rows: Default::default(),
                    deadline: Instant::now() + Duration::from_secs(20),
                    copy: None,
                    upload_confirmed: watch::channel(false).0,
                })
            }
            Err(e) => {
                let _ = r.reply.send(Err(e));
            }
        }
    }
    fn abandon_list(&mut self) {
        if let Some(active) = &self.active {
            if matches!(active.request.op, Operation::List) {
                self.abandoned.insert(
                    (active.request.channel, active.request.path.clone()),
                    active.command,
                );
            }
        }
    }
    pub(crate) fn disconnected(&mut self) {
        self.abandoned.clear();
        self.finish(Err("Connection interrupted".into()));
    }
    fn finish(&mut self, result: Outcome) {
        if let Some(mut a) = self.active.take() {
            if let Some(copy) = a.copy.take() {
                copy.abort();
            }
            let _ = a.request.reply.send(result);
        }
    }
    pub(crate) async fn poll(&mut self) {
        let Some(a) = &mut self.active else {
            return pending().await;
        };
        let result = tokio::select! {
            _=a.request.cancel.changed()=>Err("Cancelled".into()),
            _=tokio::time::sleep_until(a.deadline), if a.copy.is_none()=>Err("File request timed out".into()),
            res=async { a.copy.as_mut().unwrap().await }, if a.copy.is_some()=>res.map_err(|e|e.to_string()).and_then(|r|r.map_err(|e|e.to_string())).map(|_|vec![]),
        };
        if result.is_err() {
            self.abandon_list();
        }
        self.finish(result);
    }
    pub(crate) fn observe(&mut self, event: StreamItem) -> Option<StreamItem> {
        match &event {
            StreamItem::MessageEvent(InMessage::FileListFinished(msg)) => {
                for row in msg.iter() {
                    self.abandoned.remove(&(row.channel_id.0, row.path.clone()));
                }
            }
            StreamItem::MessageResult(h, Err(_)) => self.abandoned.retain(|_, old| old != h),
            _ => {}
        }
        let Some(a) = &mut self.active else {
            return Some(event);
        };
        match event {
            StreamItem::MessageResult(h, result) if h == a.command => {
                if let Err(e) = result {
                    if matches!(a.request.op, Operation::List)
                        && e.error == tsclientlib::TsError::DatabaseEmptyResult
                    {
                        self.finish(Ok(vec![]));
                    } else {
                        self.finish(Err(e.to_string()));
                    }
                }
            }
            StreamItem::MessageEvent(InMessage::FileList(msg))
                if matches!(a.request.op, Operation::List) =>
            {
                if msg.return_code.as_ref().is_none_or(|code| {
                    code.rsplit(':').next().and_then(|v| v.parse::<u16>().ok()) == Some(a.command.0)
                }) {
                    for row in msg.iter().filter(|r| {
                        r.channel_id.0 == a.request.channel
                            && r.path == a.request.path
                            && safe_component(&r.name)
                    }) {
                        a.rows.insert(
                            row.name.clone(),
                            RemoteChannelFile {
                                name: row.name.clone(),
                                size: row.size,
                                directory: !row.is_file,
                            },
                        );
                    }
                }
            }
            StreamItem::MessageEvent(InMessage::FileListFinished(msg))
                if matches!(a.request.op, Operation::List) =>
            {
                if msg
                    .iter()
                    .any(|r| r.channel_id.0 == a.request.channel && r.path == a.request.path)
                {
                    let rows = std::mem::take(&mut a.rows);
                    self.finish(Ok(rows.into_values().collect()));
                }
            }
            StreamItem::FiletransferFailed(id, error) if id.0 == a.id => {
                if matches!(&error, tsclientlib::Error::CommandError(e) if e.error==tsclientlib::TsError::FileTransferComplete)
                {
                    a.upload_confirmed.send_replace(true);
                } else {
                    self.finish(Err(error.to_string()));
                }
            }
            StreamItem::FileUpload(id, result) if id.0 == a.id => {
                if let Operation::Upload(file, size) = &a.request.op {
                    if result.seek_position != 0 {
                        self.finish(Err("Unexpected upload offset".into()));
                        return None;
                    }
                    match file.try_clone() {
                        Ok(f) => {
                            let size = *size;
                            let progress = a.request.progress.clone();
                            let confirmed = a.upload_confirmed.subscribe();
                            a.copy = Some(tokio::spawn(async move {
                                let mut socket = result.stream;
                                stream_exact(File::from_std(f), &mut socket, size, &progress)
                                    .await?;
                                confirm_upload(confirmed, async {
                                    let mut response = [0; 1];
                                    match socket.read(&mut response).await? {
                                        0 => Ok(()),
                                        _ => Err(io::Error::other("Unexpected upload response")),
                                    }
                                })
                                .await
                            }));
                        }
                        Err(e) => self.finish(Err(e.to_string())),
                    }
                }
            }
            StreamItem::FileDownload(id, result) if id.0 == a.id => {
                if let Operation::Download(path) = &a.request.op {
                    let path = path.clone();
                    let progress = a.request.progress.clone();
                    a.copy = Some(tokio::spawn(async move {
                        let mut file = File::create_new(path).await?;
                        stream_exact(result.stream, &mut file, result.size, &progress).await?;
                        timeout(Duration::from_secs(30), file.shutdown()).await?
                    }));
                }
            }
            other => return Some(other),
        }
        None
    }
}
// TeamSpeak sends the completion on the control connection independently of
// the file socket. An orderly EOF also works with servers that omit the status.
async fn confirm_upload(
    mut confirmed: watch::Receiver<bool>,
    close_socket: impl std::future::Future<Output = io::Result<()>>,
) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    let acknowledgement = async {
        confirmed
            .wait_for(|value| *value)
            .await
            .map(|_| ())
            .map_err(|_| io::Error::other("Connection interrupted"))
    };
    tokio::pin!(acknowledgement);
    tokio::select! {
        result = &mut acknowledgement => result,
        result = close_socket => match result {
            Err(error) if matches!(error.kind(), io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe | io::ErrorKind::NotConnected) => {
                // A reset after all writes does not tell us whether the server
                // committed the file. Only its matching status can resolve it.
                tokio::time::timeout_at(deadline, acknowledgement).await.unwrap_or(Err(error))
            }
            other => other,
        },
        _ = tokio::time::sleep_until(deadline) => Err(io::ErrorKind::TimedOut.into()),
    }
}

async fn stream_exact(
    mut reader: impl AsyncRead + Unpin,
    mut writer: impl AsyncWrite + Unpin,
    mut remaining: u64,
    progress: &Progress,
) -> io::Result<()> {
    progress.total.store(remaining, Ordering::Relaxed);
    let mut buf = vec![0; 64 * 1024];
    let idle = Duration::from_secs(30);
    while remaining > 0 {
        let limit = remaining.min(buf.len() as u64) as usize;
        let count = timeout(idle, reader.read(&mut buf[..limit])).await??;
        if count == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        timeout(idle, writer.write_all(&buf[..count])).await??;
        remaining -= count as u64;
        progress.bytes.fetch_add(count as u64, Ordering::Relaxed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_names_are_single_components() {
        for name in ["", ".", "..", "../secret", "a/b", "a\\b", "a\0b"] {
            assert!(!safe_component(name));
        }
        assert!(safe_component("音频 01.opus"));
    }

    #[tokio::test]
    async fn copy_checks_length_and_reports_progress() {
        let bytes = vec![0x35; 200_000];
        let mut destination = Vec::new();
        let progress = Progress::default();
        stream_exact(
            bytes.as_slice(),
            &mut destination,
            bytes.len() as u64,
            &progress,
        )
        .await
        .unwrap();
        assert_eq!(destination, bytes);
        assert_eq!(progress.bytes.load(Ordering::Relaxed), 200_000);
        assert_eq!(
            stream_exact(&b"short"[..], tokio::io::sink(), 6, &Progress::default())
                .await
                .unwrap_err()
                .kind(),
            io::ErrorKind::UnexpectedEof
        );
    }
    fn active(op: Operation) -> (Worker, watch::Sender<bool>, oneshot::Receiver<Outcome>) {
        let (cancel, cancel_rx) = watch::channel(false);
        let (reply, rx) = oneshot::channel();
        let request = Request {
            channel: 3,
            path: "/".into(),
            generation: 0,
            password: String::new(),
            op,
            cancel: cancel_rx,
            reply,
            progress: Default::default(),
        };
        let worker = Worker {
            active: Some(Active {
                request,
                command: MessageHandle(7),
                id: 42,
                rows: Default::default(),
                deadline: Instant::now() + Duration::from_secs(5),
                copy: None,
                upload_confirmed: watch::channel(false).0,
            }),
            next_id: 42,
            abandoned: Default::default(),
        };
        (worker, cancel, rx)
    }
    fn notification(payload: &[u8]) -> StreamItem {
        use tsproto_packets::packets::{Direction, InHeader, PacketType};
        let mut header = [0; 11];
        header[10] = PacketType::Command as u8;
        StreamItem::MessageEvent(
            InMessage::new(&InHeader::new(Direction::S2C, &header), payload).unwrap(),
        )
    }

    #[tokio::test]
    async fn directory_notifications_are_scoped_and_deduplicated() {
        let (mut worker, _cancel, rx) = active(Operation::List);
        for line in [
            &b"notifyfilelist cid=3 path=/ return_code=1:8 name=stale size=1 datetime=100 type=1"[..],
            b"notifyfilelist cid=3 path=/ return_code=1:7 name=one size=100 datetime=100 type=1",
            b"notifyfilelist cid=3 path=/ return_code=1:7 name=one size=120 datetime=101 type=1",
            b"notifyfilelist cid=3 path=/ return_code=1:7 name=sub size=0 datetime=100 type=0",
            b"notifyfilelistfinished cid=4 path=/",
            b"notifyfilelistfinished cid=3 path=/",
        ] {
            worker.observe(notification(line));
        }
        let rows = rx.await.unwrap().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!((rows[0].name.as_str(), rows[0].size), ("one", 120));
        assert!(rows[1].directory);
    }

    #[tokio::test]
    async fn cancelled_list_drains_its_unkeyed_completion() {
        let (mut worker, cancel, rx) = active(Operation::List);
        cancel.send_replace(true);
        worker.poll().await;
        assert!(rx.await.unwrap().is_err());
        assert_eq!(worker.abandoned.len(), 1);
        worker.observe(notification(b"notifyfilelistfinished cid=3 path=/"));
        assert!(worker.abandoned.is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn reset_after_upload_needs_matching_server_confirmation() {
        let source = || std::fs::File::open("Cargo.toml").unwrap();
        let (mut worker, _cancel, mut done) = active(Operation::Upload(source(), 32));
        let confirmation = worker.active.as_ref().unwrap().upload_confirmed.subscribe();
        worker.active.as_mut().unwrap().copy =
            Some(tokio::spawn(confirm_upload(confirmation, async {
                Err(io::ErrorKind::ConnectionReset.into())
            })));
        tokio::task::yield_now().await;
        let status = |id| {
            StreamItem::FiletransferFailed(
                tsclientlib::FiletransferHandle(id),
                tsclientlib::CommandError {
                    error: tsclientlib::TsError::FileTransferComplete,
                    missing_permission: None,
                }
                .into(),
            )
        };
        worker.observe(status(41));
        assert!(done.try_recv().is_err());
        worker.observe(status(42));
        worker.poll().await;
        assert!(done.await.unwrap().is_ok());

        let (_tx, rx) = watch::channel(false);
        let failure = confirm_upload(rx, async { Err(io::ErrorKind::ConnectionReset.into()) })
            .await
            .unwrap_err();
        assert_eq!(failure.kind(), io::ErrorKind::ConnectionReset);
    }

    #[tokio::test]
    async fn early_server_completion_cannot_override_short_source() {
        let (mut worker, _cancel, done) = active(Operation::Upload(
            std::fs::File::open("Cargo.toml").unwrap(),
            32,
        ));
        worker.observe(StreamItem::FiletransferFailed(
            tsclientlib::FiletransferHandle(42),
            tsclientlib::CommandError {
                error: tsclientlib::TsError::FileTransferComplete,
                missing_permission: None,
            }
            .into(),
        ));
        assert!(*worker.active.as_ref().unwrap().upload_confirmed.borrow());
        worker.active.as_mut().unwrap().copy = Some(tokio::spawn(async {
            stream_exact(&b"short"[..], tokio::io::sink(), 32, &Progress::default()).await
        }));
        worker.poll().await;
        assert!(done.await.unwrap().is_err());
    }

    #[tokio::test]
    async fn negotiated_streams_round_trip_over_tcp() {
        use tokio::net::{TcpListener, TcpStream};
        use tsclientlib::{FileDownloadResult, FileUploadResult, FiletransferHandle};
        let bytes: Vec<_> = (0..200_000).map(|i| (i % 251) as u8).collect();
        let directory =
            std::env::temp_dir().join(format!("opents-file-roundtrip-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        let source = directory.join("source");
        let destination = directory.join("destination");
        std::fs::write(&source, &bytes).unwrap();
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            // The size came from ftinitupload. The protocol does not require
            // the client to close its writing half to delimit the payload.
            let mut remote = vec![0; 200_000];
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.read_exact(&mut remote).await.unwrap();
            drop(socket);
            let (mut socket, _) = listener.accept().await.unwrap();
            socket.write_all(&remote).await.unwrap();
            socket.shutdown().await.unwrap();
        });
        let size = bytes.len() as u64;
        let (mut upload, _u, done) = active(Operation::Upload(
            std::fs::File::open(source).unwrap(),
            size,
        ));
        upload.observe(StreamItem::FileUpload(
            FiletransferHandle(42),
            FileUploadResult {
                seek_position: 0,
                stream: TcpStream::connect(addr).await.unwrap(),
            },
        ));
        upload.poll().await;
        done.await.unwrap().unwrap();
        let (mut download, _d, done) = active(Operation::Download(destination.clone()));
        download.observe(StreamItem::FileDownload(
            FiletransferHandle(42),
            FileDownloadResult {
                size,
                stream: TcpStream::connect(addr).await.unwrap(),
            },
        ));
        download.poll().await;
        done.await.unwrap().unwrap();
        server.await.unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), bytes);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
