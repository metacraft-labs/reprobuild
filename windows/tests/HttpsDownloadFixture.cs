// Owned real socket/TLS origin for the PowerShell downloader tests. Certificates
// and private keys exist only in this process; no certificate store is edited.
// Each Evidence instance belongs to one reset transaction, and workers retain
// that instance so stale work cannot certify a later request.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

namespace VerifiedDownloadTests
{
    public static class Certificates
    {
        public static X509Certificate2 Create(bool expired)
        {
            using (RSA rsa = RSA.Create())
            {
                rsa.KeySize = 2048;
                RSACryptoServiceProvider csp = rsa as RSACryptoServiceProvider;
                if (csp != null) csp.PersistKeyInCsp = false;
                CertificateRequest request = new CertificateRequest("CN=localhost", rsa,
                    HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                SubjectAlternativeNameBuilder names = new SubjectAlternativeNameBuilder();
                names.AddDnsName("localhost");
                request.CertificateExtensions.Add(names.Build());
                request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
                request.CertificateExtensions.Add(new X509KeyUsageExtension(
                    X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
                OidCollection uses = new OidCollection();
                uses.Add(new Oid("1.3.6.1.5.5.7.3.1"));
                request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(uses, true));
                DateTimeOffset now = DateTimeOffset.UtcNow;
                return request.CreateSelfSigned(now.AddDays(-2), expired ? now.AddDays(-1) : now.AddDays(1));
            }
        }
    }

    // The fixture certificate is an explicit, exact leaf trust anchor. Only its
    // otherwise-untrusted self-signed root is accepted: identity, actual request
    // hostname, validity and every other chain error are still checked.
    public sealed class CertificatePin
    {
        private readonly byte[] expected;
        public volatile string LastFailure = "";
        public volatile string AcceptedUri = "";
        public CertificatePin(X509Certificate2 certificate) { expected = certificate.RawData; }
        public void Reset() { LastFailure = ""; AcceptedUri = ""; }
        private bool Refuse(string reason) { LastFailure = reason; return false; }
        private bool Validate(object request, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            if (certificate == null) return Refuse("identity");
            byte[] actual = certificate.GetRawCertData();
            if (actual.Length != expected.Length) return Refuse("identity");
            for (int i = 0; i < actual.Length; i++) if (actual[i] != expected[i]) return Refuse("identity");
            using (X509Certificate2 cert = new X509Certificate2(certificate))
            {
                DateTime now = DateTime.UtcNow;
                if (now < cert.NotBefore.ToUniversalTime() || now > cert.NotAfter.ToUniversalTime())
                    return Refuse("validity");
            }
            // Both actual request types expose RequestUri (HttpRequestMessage
            // in Core, HttpWebRequest in the Framework WebRequestHandler).
            var property = request.GetType().GetProperty("RequestUri");
            Uri uri = property == null ? null : property.GetValue(request, null) as Uri;
            if (uri == null || uri.Host != "localhost" ||
                (errors & (SslPolicyErrors.RemoteCertificateNameMismatch | SslPolicyErrors.RemoteCertificateNotAvailable)) != 0)
                return Refuse("hostname");
            if (chain == null) return Refuse("chain");
            foreach (X509ChainStatus item in chain.ChainStatus)
                if ((item.Status & ~X509ChainStatusFlags.UntrustedRoot) != 0) return Refuse("chain");
            AcceptedUri = uri.AbsoluteUri;
            return true;
        }
        public bool Core(System.Net.Http.HttpRequestMessage request, X509Certificate2 certificate, X509Chain chain, SslPolicyErrors errors)
        { return Validate(request, certificate, chain, errors); }
        public bool Desktop(object request, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        { return Validate(request, certificate, chain, errors); }
    }

    public sealed class Evidence
    {
        public readonly string Id;
        public readonly string Mode;
        public int TcpConnections, Handshakes, Requests, Headers, BodyChunks, BodyBytes, Redirects;
        public volatile string RequestedPath = "";
        public volatile string Failure = "";
        private long firstBody, lastBody;
        public Evidence(string id, string mode) { Id = id; Mode = mode; }
        public void Body(int count)
        {
            long now = Stopwatch.GetTimestamp();
            Interlocked.CompareExchange(ref firstBody, now, 0);
            Interlocked.Exchange(ref lastBody, now);
            Interlocked.Increment(ref BodyChunks);
            Interlocked.Add(ref BodyBytes, count);
        }
        public double ProgressSeconds
        { get { return (Interlocked.Read(ref lastBody) - Interlocked.Read(ref firstBody)) / (double)Stopwatch.Frequency; } }
    }

    public sealed class HttpsFixture : IDisposable
    {
        private readonly X509Certificate2 certificate;
        private readonly TcpListener http, https;
        private readonly Thread httpThread, httpsThread;
        private readonly ManualResetEvent stop = new ManualResetEvent(false);
        private readonly object gate = new object();
        private readonly List<TcpClient> clients = new List<TcpClient>();
        private volatile Evidence evidence;
        public Evidence Current { get { return evidence; } }
        public int HttpPort { get { return ((IPEndPoint)http.LocalEndpoint).Port; } }
        public int HttpsPort { get { return ((IPEndPoint)https.LocalEndpoint).Port; } }
        public HttpsFixture(X509Certificate2 cert)
        {
            certificate = cert;
            evidence = new Evidence(Guid.NewGuid().ToString("N"), "normal");
            http = new TcpListener(IPAddress.Loopback, 0);
            https = new TcpListener(IPAddress.Loopback, 0);
            http.Start(); https.Start();
            httpThread = new Thread(delegate() { Accept(http, false); });
            httpsThread = new Thread(delegate() { Accept(https, true); });
            httpThread.IsBackground = true; httpsThread.IsBackground = true;
            httpThread.Start(); httpsThread.Start();
        }
        public void Reset(string id, string mode)
        {
            // A cancellation may leave a worker between body writes. Wait for
            // that worker to observe the closed socket before starting an epoch.
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                lock (gate)
                {
                    if (clients.Count == 0 && !http.Pending() && !https.Pending())
                    { evidence = new Evidence(id, mode); return; }
                }
                if (timer.Elapsed.TotalSeconds > 6) throw new Exception("Fixture did not become idle before reset.");
                Thread.Sleep(10);
            }
        }
        private void Accept(TcpListener listener, bool tls)
        {
            try
            {
                while (!stop.WaitOne(5))
                {
                    if (!listener.Pending()) continue;
                    TcpClient client;
                    Evidence transaction;
                    lock (gate)
                    {
                        client = listener.AcceptTcpClient();
                        clients.Add(client);
                        transaction = evidence;
                    }
                    ThreadPool.QueueUserWorkItem(delegate(object ignored) { Serve(client, tls, transaction); });
                }
            }
            catch (Exception ex) { if (!stop.WaitOne(0)) evidence.Failure = ex.ToString(); }
        }
        private void Write(Stream stream, string text)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(text);
            stream.Write(bytes, 0, bytes.Length); stream.Flush();
        }
        private void Redirect(Stream stream, string location, Evidence transaction)
        {
            Write(stream, "HTTP/1.1 302 Found\r\nLocation: " + location +
                "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            Interlocked.Increment(ref transaction.Redirects);
        }
        private void Serve(TcpClient client, bool tls, Evidence transaction)
        {
            try
            {
                NetworkStream network = client.GetStream();
                network.ReadTimeout = 5000; network.WriteTimeout = 5000;
                Stream stream = network;
                if (tls)
                {
                    Interlocked.Increment(ref transaction.TcpConnections);
                    if (transaction.Mode == "no-tls") { stop.WaitOne(5500); return; }
                    SslStream secured = new SslStream(network, false);
                    secured.AuthenticateAsServer(certificate, false, SslProtocols.Tls12, false);
                    stream = secured;
                    Interlocked.Increment(ref transaction.Handshakes);
                }
                using (stream)
                {
                    string line;
                    using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true))
                    {
                        line = reader.ReadLine();
                        if (line == null) return;
                        while (!String.IsNullOrEmpty(reader.ReadLine())) { }
                    }
                    string path = line.Split(' ')[1];
                    if (!path.Contains(transaction.Id)) throw new Exception("Request belongs to another transaction: " + path);
                    if (!tls)
                    {
                        if (stop.WaitOne(3000)) return;
                        Redirect(stream, "https://localhost:" + HttpsPort + "/body/" + transaction.Id, transaction);
                        return;
                    }
                    transaction.RequestedPath = path;
                    Interlocked.Increment(ref transaction.Requests);
                    if (path.StartsWith("/relative/")) { Redirect(stream, "/good/" + transaction.Id, transaction); return; }
                    if (path.StartsWith("/loop/")) { Redirect(stream, "#loop", transaction); return; }
                    if (path.StartsWith("/chain/"))
                    {
                        int remaining = Int32.Parse(path.Substring(path.LastIndexOf('/') + 1));
                        if (remaining > 0)
                        { Redirect(stream, "/chain/" + transaction.Id + "/" + (remaining - 1), transaction); return; }
                    }
                    Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: 64\r\nConnection: close\r\n\r\n");
                    Interlocked.Increment(ref transaction.Headers);
                    if (transaction.Mode == "no-body") { stop.WaitOne(5500); return; }
                    byte[] chunk = Encoding.ASCII.GetBytes("****");
                    for (int i = 0; i < 16; i++)
                    {
                        stream.Write(chunk, 0, chunk.Length); stream.Flush();
                        transaction.Body(chunk.Length);
                        if (path.StartsWith("/body/") && stop.WaitOne(250)) return;
                    }
                }
            }
            catch (IOException) { /* Expected when a real client cancels or rejects TLS. */ }
            catch (AuthenticationException) { /* Certificate refusal controls. */ }
            catch (Exception ex) { transaction.Failure = ex.ToString(); }
            finally
            {
                client.Dispose();
                lock (gate) clients.Remove(client);
            }
        }
        public void Dispose()
        {
            stop.Set(); http.Stop(); https.Stop();
            lock (gate) foreach (TcpClient client in clients) client.Dispose();
            if (!httpThread.Join(2000) || !httpsThread.Join(2000)) throw new Exception("Fixture listeners did not stop.");
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                lock (gate) if (clients.Count == 0) break;
                if (timer.Elapsed.TotalSeconds > 3) throw new Exception("Fixture connections did not stop.");
                Thread.Sleep(10);
            }
            stop.Dispose();
        }
    }
}
