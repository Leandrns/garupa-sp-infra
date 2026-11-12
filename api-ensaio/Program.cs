// API de ensaio: publicada pelo 02_app.sh quando APP_REPO_URL está vazio.
// Só tem o health check do contrato, suficiente para testar a infra sem a API do grupo.
using System.Net.Sockets;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/api/v1/saude", async () =>
{
    // O banco está ok se a porta do PostgreSQL aceitar conexão.
    bool bancoOk;
    try
    {
        using var cliente = new TcpClient();
        await cliente.ConnectAsync("127.0.0.1", 5432).WaitAsync(TimeSpan.FromSeconds(2));
        bancoOk = true;
    }
    catch
    {
        bancoOk = false;
    }

    var corpo = new
    {
        versao = "ensaio-infra",
        banco = bancoOk ? "ok" : "indisponivel",
        horaUtc = DateTime.UtcNow
    };

    // 503: a API está viva, mas o banco não.
    return bancoOk ? Results.Ok(corpo) : Results.Json(corpo, statusCode: 503);
});

app.MapGet("/", () => Results.Text("Garupa SP - API de ensaio. Use /api/v1/saude"));

app.Run();
