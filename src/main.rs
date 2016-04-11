extern crate discord;
extern crate markov;

use discord::Discord;
use discord::model::Event;
use markov::Chain;

fn main() {
    let discord = Discord::from_bot_token(
        "MTY4ODQ4MTQwODYxMDQ2Nzg0.CexjlQ.OTmVLXOLzShEizIVhZa_KnpSIts"
    )
        .expect("Couldn't log in dude.");

    let (mut connection, _) = discord.connect().expect("Connection failed.");
    println!("Here we go");
    loop {
        match connection.recv_event() {
            Ok(Event::MessageCreate(message)) => {
                println!("{} says: {}", message.author.name, message.content);
            }

            Ok(_) => {}
            Err(discord::Error::Closed(code, body)) => {
                println!("Connection closed {:?}: {}", code, String::from_utf8_lossy(&body));
            }
            Err(e) => println!("Error {:?}", e)
        }
    }

    discord.logout.unwrap();
}
