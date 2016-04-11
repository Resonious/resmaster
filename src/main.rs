extern crate discord;
extern crate markov;

use discord::{Discord, ChannelRef, State};
use discord::model::{Event, ChannelType};
use markov::Chain;

const BOT_TOKEN = "MTY4ODY2MDQ5NjI0NzY4NTEy.Cex0Qw.RyZsacSKKKxpiVtAZ6JueJwTeMQ";

fn main() {
    println!("connecting?");
    let (mut connection, _) = discord.connect().expect("Connection failed.");
    println!("Here we go");
    loop {
        match connection.recv_event() {
            Ok(Event::MessageCreate(message)) => {
                println!("{} says: {}", message.author.name, message.content);
            }

            Ok(_) => {}
            Err(e) => println!("Error {:?}", e)
        }
    }

    discord.logout().unwrap();
}
