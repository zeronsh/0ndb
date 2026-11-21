use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

pub(crate) struct QueueState<T> {
    pub items: VecDeque<T>,
    pub closed: bool,
    pub dropping: bool,
    waker: Option<Waker>,
}

pub(crate) struct Queue<T> {
    state: Mutex<QueueState<T>>,
    ready: Condvar,
    hook: Option<fn(&T, &mut QueueState<T>)>,
}

impl<T> Queue<T> {
    pub fn new() -> Arc<Self> {
        Queue::with_hook(None)
    }

    pub fn with_hook(hook: Option<fn(&T, &mut QueueState<T>)>) -> Arc<Self> {
        Arc::new(Queue {
            hook,
            state: Mutex::new(QueueState {
                items: VecDeque::new(),
                closed: false,
                dropping: false,
                waker: None,
            }),
            ready: Condvar::new(),
        })
    }

    fn take(&self, g: &mut QueueState<T>) -> Option<T> {
        let x = g.items.pop_front()?;
        if let Some(h) = self.hook {
            h(&x, g);
        }
        Some(x)
    }

    pub fn lock(&self) -> MutexGuard<'_, QueueState<T>> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn notify(&self, mut g: MutexGuard<'_, QueueState<T>>) {
        let w = g.waker.take();
        drop(g);
        self.ready.notify_all();
        if let Some(w) = w {
            w.wake();
        }
    }

    pub fn push(&self, item: T) {
        let mut g = self.lock();
        g.items.push_back(item);
        self.notify(g);
    }

    pub fn close(&self) {
        let mut g = self.lock();
        g.closed = true;
        self.notify(g);
    }

    pub fn try_pop(&self) -> Option<T> {
        let mut g = self.lock();
        self.take(&mut g)
    }

    pub fn pop_blocking(&self, timeout: Option<Duration>) -> Option<T> {
        let mut g = self.lock();
        let deadline = timeout.map(|t| std::time::Instant::now() + t);
        loop {
            if let Some(x) = self.take(&mut g) {
                return Some(x);
            }
            if g.closed {
                return None;
            }
            match deadline {
                None => g = self.ready.wait(g).unwrap_or_else(|e| e.into_inner()),
                Some(d) => {
                    let now = std::time::Instant::now();
                    if now >= d {
                        return None;
                    }
                    g = self.ready.wait_timeout(g, d - now).unwrap_or_else(|e| e.into_inner()).0;
                }
            }
        }
    }

    pub fn poll_pop(&self, cx: &mut Context<'_>) -> Poll<Option<T>> {
        let mut g = self.lock();
        if let Some(x) = self.take(&mut g) {
            return Poll::Ready(Some(x));
        }
        if g.closed {
            return Poll::Ready(None);
        }
        g.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}

pub struct Next<'a, T> {
    pub(crate) queue: &'a Queue<T>,
}

impl<T> Future for Next<'_, T> {
    type Output = Option<T>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<T>> {
        self.queue.poll_pop(cx)
    }
}
